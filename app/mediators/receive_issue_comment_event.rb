# encoding: utf-8
# frozen_string_literal: true

class ReceiveIssueCommentEvent
  include Sidekiq::Worker
  include GithubApi
  include Skylight::Helpers
  DIRECTIVE_REGEX = /([A-Za-z0-9_-]+)=\s?@?([A-Za-z0-9_-]+)/

  instrument_method
  def perform(payload)
    Current.reset

    @payload = payload

    Raven.user_context(
      username: @payload["sender"]["login"]
    )
    Raven.tags_context(
      event: "pull_request",
      repo: @payload["repository"]["full_name"]
    )

    if (installation_id = @payload.dig("installation", "id"))
      Current.installation_id = installation_id
    end

    # check for ignored labels
    @repository =
      Repository.find_by_full_name(@payload["repository"]["full_name"])

    labels = @payload["issue"]["labels"].map { |label| label["name"] }
    if @repository.ignore?(labels)
      Current.reset
      return
    end

    comment = @payload["comment"]["body"]

    PaperTrail.request(whodunnit: @payload["sender"]["login"]) do
      if comment_affirmative?(comment)
        self.approval_comment
      elsif comment_rebuild_reviews?(comment)
        self.rebuild_reviews
      elsif directives = comment_replace?(comment)
        replace_reviewer(directives)
      elsif comment_replace_me?(comment)
        replace_me
      end
    end

    Current.reset
  end

  instrument_method
  def approval_comment
    pr = find_pull_request(@payload)
    return unless pr

    # Do not process approval comments on child PRs
    return if pr.parent_pull_request.present?

    comment = @payload["comment"]["body"]
    return unless comment_affirmative?(comment)

    comment_author = @payload["sender"]["login"]
    reviewer = pr.reviewers.pending_review.find_by(login: comment_author)
    return unless reviewer.present?

    reviewer.approve!

    if pr.reviewers.pending_review.empty?
      pr.status = "approved"
      pr.save!
      pr.update_status
    end

    pr.assign_reviewers

    CommandInvocation.record_invocation(
      command: "cody approve",
      args: "",
      login: @payload["sender"]["login"],
      pull_request_id: pr.id
    )
  end

  instrument_method
  def rebuild_reviews
    pull_request = github_client.pull_request(
      @payload["repository"]["full_name"],
      @payload["issue"]["number"]
    )

    CreateOrUpdatePullRequest.new.perform(pull_request)
  end

  # Checks if the given string can be taken as an affirmative review.
  #
  # Recognized approval phrases (all case insensitive):
  #
  # * "LGTM"
  # * ":+1:" # the GitHub thumbs-up emoji string
  # * "Looks good"
  # * "Looks good to me"
  #
  # comment - String to check
  #
  # Returns true if the comment is affirmative; false otherwise.
  def comment_affirmative?(comment)
    return true if comment == "cody approve"

    phrases = %w(
      lgtm
      looks\s+good(?:\s+to\s+me)?
      👍
      🆗
      🚀
      💯
    )

    # emojis need some extra processing so we handle them separately
    emojis = %w(
      \+1
      ok
      shipit
      rocket
      100
    ).map { |e| ":#{e}:" }

    affirmatives = (phrases + emojis).map { |a| "(^\\s*#{a}\\s*$)" }
    joined = affirmatives.join("|")

    !!(comment =~ /#{joined}/i)
  end

  def comment_rebuild_reviews?(comment)
    comment == "!rebuild-reviews" ||
      comment == "cody rebuild"
  end

  def comment_replace?(comment)
    return false unless comment =~ /^cody\s+r(eplace)?\s+(?<directives>.*)$/

    directives = $LAST_MATCH_INFO[:directives]
    return false unless directives.match?(DIRECTIVE_REGEX)
    directives
  end

  def comment_replace_me?(comment)
    comment.match?(/^cody\s+r(eplace)?\s+(me).*$/)
  end

  instrument_method
  def replace_reviewer(directives)
    pr = find_pull_request(@payload)
    return false unless pr

    directives.scan(DIRECTIVE_REGEX).each do |code, login|
      reviewer = pr.generated_reviewers
        .joins(:review_rule)
        .find_by(review_rules: { short_code: code })

      next unless reviewer.present?

      next unless reviewer.review_rule.possible_reviewer?(login)

      reviewer.update!(login: login)
    end

    pr.reload
    pr.update_body
    pr.assign_reviewers

    CommandInvocation.record_invocation(
      command: "cody replace",
      args: directives,
      login: @payload["sender"]["login"],
      pull_request_id: pr.id
    )
  end

  instrument_method
  def replace_me
    pr = find_pull_request(@payload)
    return false unless pr

    commenter = @payload["sender"]["login"]

    old_reviewers = pr.reviewers.where(
      login: commenter,
      status: Reviewer::STATUS_PENDING_APPROVAL
    )
    return unless old_reviewers.present?

    old_reviewers.each do |reviewer|
      pos_logins = reviewer.review_rule.filtered_reviewers(pr)
      new_usr = pos_logins.reject { |usr| usr.casecmp(commenter).zero? }.sample
      reviewer.update!(login: new_usr) if new_usr
    end

    pr.reload
    pr.update_body
    pr.assign_reviewers
  end

  private

  def find_pull_request(payload)
    PullRequest.joins(:repository).pending_review.find_by(
      number: payload["issue"]["number"],
      repositories: {
        owner: payload["repository"]["owner"]["login"],
        name: payload["repository"]["name"]
      }
    )
  end
end
