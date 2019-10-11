// @flow

import React from "react";
import { createFragmentContainer, graphql } from "react-relay";
import { type ReviewRuleList_repository } from "./__generated__/ReviewRuleList_repository.graphql";

const ReviewRuleList = ({
  repository
}: {
  repository: ReviewRuleList_repository
}) => (
  <section className="section">
    <div className="container">
      <h1 className="title">Review Rules</h1>

      <table className="table is-fullwidth is-hoverable">
        <thead>
          <tr>
            <th>Name</th>
            <th>Short Code</th>
            <th>Reviewer</th>
            <th>Match</th>
          </tr>
        </thead>
        <tbody>
          {repository.reviewRules != null &&
          repository.reviewRules.edges != null
            ? repository.reviewRules.edges.map(edge => {
                if (edge != null && edge.node != null) {
                  return (
                    <tr>
                      <td>{edge.node.name}</td>
                      <td>{edge.node.shortCode}</td>
                      <td>{edge.node.reviewer}</td>
                      <td className="code">{edge.node.match}</td>
                    </tr>
                  );
                }
              })
            : null}
        </tbody>
      </table>
    </div>
  </section>
);

export default createFragmentContainer(
  ReviewRuleList,
  graphql`
    fragment ReviewRuleList_repository on Repository {
      owner
      name
      reviewRules(first: 200, after: $cursor)
        @connection(key: "ReviewRuleList_reviewRules") {
        edges {
          node {
            id
            name
            shortCode
            match
            reviewer
          }
        }
      }
    }
  `
);
