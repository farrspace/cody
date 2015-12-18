class ReceivePullRequestEvent
  include Sidekiq::Worker

  def perform(payload)
    reviewers = payload["pull_request"]["body"].scan(/- \[.\] @(.+)/).flatten
    
    number = payload["number"]

    PullRequest.create!(number: number, status: "pending_review", pending_reviews: reviewers)

    pr_sha = payload["pull_request"]["head"]["sha"]

    github = Octokit::Client.new(access_token: ENV["CODY_GITHUB_ACCESS_TOKEN"])
    github.create_status(ENV["CODY_GITHUB_REPO"], pr_sha, "pending", context: "code-review/cody", description: "Not all reviewers have approved")
  end
end
