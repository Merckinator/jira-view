import gleam/json.{parse}
import gleam/list
import gleam/option.{Some}
import gleeunit
import gleeunit/should
import shared/adf
import shared/types

pub fn main() {
  gleeunit.main()
}

// decoding against the shape of a captured Jira /rest/api/3/myself response

const sample_myself =
  "
{
  \"accountId\": \"557058:f1a2b3c4\",
  \"displayName\": \"Jeff Merckens\",
  \"emailAddress\": \"jeff@example.com\",
  \"timeZone\": \"America/New_York\",
  \"avatarUrls\": {
    \"16x16\": \"https://acme.atlassian.net/16.png\",
    \"48x48\": \"https://acme.atlassian.net/48.png\"
  }
}
"

pub fn decode_me_test() {
  let assert Ok(me) = parse(sample_myself, types.me_decoder())
  me.account_id |> should.equal("557058:f1a2b3c4")
  me.display_name |> should.equal("Jeff Merckens")
  me.email |> should.equal("jeff@example.com")
  me.avatar_url |> should.equal("https://acme.atlassian.net/48.png")
  me.time_zone |> should.equal("America/New_York")
}

pub fn decode_me_missing_optional_fields_test() {
  let assert Ok(me) =
    parse(
      "{
        \"accountId\": \"abc\",
        \"displayName\": \"Jeff\",
        \"avatarUrls\": {\"48x48\": \"https://acme.atlassian.net/48.png\"}
      }",
      types.me_decoder(),
    )
  me.email |> should.equal("")
  me.time_zone |> should.equal("")
}

// decoding the assignable-user search and the backend's app-shaped wrapper

const sample_assignable_users =
  "[{\"accountId\":\"557058:f1a2b3c4\",\"displayName\":\"Jeff Merckens\",\"avatarUrls\":{\"48x48\":\"https://acme.atlassian.net/48.png\"}}]"

pub fn decode_jira_users_test() {
  parse(sample_assignable_users, types.jira_users_decoder())
  |> should.equal(
    Ok([
      types.User(
        "557058:f1a2b3c4",
        "Jeff Merckens",
        "https://acme.atlassian.net/48.png",
      ),
    ]),
  )
}

pub fn decode_users_response_test() {
  parse(
    "{\"users\":[{\"account_id\":\"abc\",\"display_name\":\"Jeff\",\"avatar_url\":\"u\"}]}",
    types.users_response_decoder(),
  )
  |> should.equal(Ok([types.User("abc", "Jeff", "u")]))
}

// decoding against the shape of a captured Jira /rest/api/3/search/jql
// page (project KAN, bounded jql, fields=summary,status,assignee,updated)

const sample_search_page =
  "
{
  \"nextPageToken\": \"EAMYscSMiZU0IiNjcmVhdGVkPj0tMzBk\",
  \"isLast\": false,
  \"issues\": [
    {
      \"id\": \"10012\",
      \"key\": \"KAN-3\",
      \"fields\": {
        \"summary\": \"Subtask 2.1\",
        \"assignee\": null,
        \"updated\": \"2026-10-18T18:05:33.688-0400\",
        \"status\": {
          \"description\": \"\",
          \"name\": \"To Do\",
          \"id\": \"10003\",
          \"statusCategory\": {\"key\": \"new\", \"name\": \"To Do\"}
        }
      }
    },
    {
      \"id\": \"10010\",
      \"key\": \"KAN-1\",
      \"fields\": {
        \"summary\": \"Create a demo project\",
        \"labels\": [\"demo\", \"docs\"],
        \"assignee\": {
          \"accountId\": \"557058:f1a2b3c4-5678\",
          \"displayName\": \"Jeff Merckens\",
          \"avatarUrls\": {\"48x48\": \"https://acme.atlassian.net/48.png\"}
        },
        \"updated\": \"2026-10-17T10:00:00.000-0400\",
        \"status\": {
          \"name\": \"In Progress\",
          \"statusCategory\": {\"key\": \"indeterminate\", \"name\": \"In Progress\"}
        }
      }
    }
  ]
}
"

pub fn decode_search_page_test() {
  let assert Ok(page) = parse(sample_search_page, types.search_page_decoder())
  page.issues |> list.length |> should.equal(2)
  page.next_page_token |> should.equal(Some("EAMYscSMiZU0IiNjcmVhdGVkPj0tMzBk"))

  let assert [first, second] = page.issues
  first.key |> should.equal("KAN-3")
  first.id |> should.equal("10012")
  first.summary |> should.equal("Subtask 2.1")
  first.assignee |> should.be_none
  first.labels |> should.equal([])
  first.status |> should.equal(types.Status("To Do", "new"))
  first.updated |> should.equal("2026-10-18T18:05:33.688-0400")

  second.assignee |> should.be_some
  second.labels |> should.equal(["demo", "docs"])
  let assert Some(assignee) = second.assignee
  assignee.display_name |> should.equal("Jeff Merckens")
  assignee.account_id |> should.equal("557058:f1a2b3c4-5678")
  assignee.avatar_url |> should.equal("https://acme.atlassian.net/48.png")
  second.status |> should.equal(types.Status("In Progress", "indeterminate"))
}

// last page of a real capture: "isLast": true and no nextPageToken at all

pub fn decode_search_last_page_test() {
  let assert Ok(page) =
    parse("{\"issues\": [], \"isLast\": true}", types.search_page_decoder())
  page.issues |> should.equal([])
  page.next_page_token |> should.be_none
}

// a user without avatarUrls and a status without statusCategory still decode
// (the fields allowlist is enforced on the request side; tolerating their
// absence keeps the decoders quiet about rendering-only details)

pub fn decode_search_page_missing_optional_bits_test() {
  let assert Ok(page) =
    parse(
      "{
        \"issues\": [
          {
            \"id\": \"1\",
            \"key\": \"KAN-9\",
            \"fields\": {
              \"summary\": \"s\",
              \"assignee\": {\"displayName\": \"Jeff\"},
              \"updated\": \"2026-10-17T10:00:00.000-0400\",
              \"status\": {\"name\": \"To Do\"}
            }
          }
        ]
      }",
      types.search_page_decoder(),
    )
  let assert [only] = page.issues
  only.status.category |> should.equal("")
  let assert Some(user) = only.assignee
  user.avatar_url |> should.equal("")
  user.account_id |> should.equal("")
}

// missing required fields surface loudly instead of rendering garbage

pub fn decode_search_page_missing_summary_is_error_test() {
  let parsed =
    parse(
      "{
        \"issues\": [
          {\"id\": \"1\", \"key\": \"KAN-9\", \"fields\": {}}
        ]
      }",
      types.search_page_decoder(),
    )
  parsed |> should.be_error
}

// issue detail: description ADF tree, nullable assignee; "content": [] when
// there is no description (real capture of KAN-2)

pub fn decode_issue_detail_test() {
  let assert Ok(detail) =
    parse(
      "{
        \"id\": \"10011\",
        \"key\": \"KAN-2\",
        \"fields\": {
          \"summary\": \"Task 2\",
          \"assignee\": null,
          \"updated\": \"2026-10-18T18:05:32.795-0400\",
          \"status\": {
            \"name\": \"In Progress\",
            \"statusCategory\": {\"key\": \"indeterminate\", \"name\": \"In Progress\"}
          },
          \"description\": {\"type\": \"doc\", \"version\": 1, \"content\": []}
        }
      }",
      types.issue_detail_decoder(),
    )

  detail.issue.key |> should.equal("KAN-2")
  detail.issue.summary |> should.equal("Task 2")
  detail.description |> should.equal([])
}

pub fn decode_issue_detail_without_description_test() {
  let assert Ok(detail) =
    parse(
      "{
        \"id\": \"1\",
        \"key\": \"KAN-1\",
        \"fields\": {
          \"summary\": \"Create a demo project\",
          \"updated\": \"2026-10-17T10:00:00.000-0400\",
          \"status\": {\"name\": \"To Do\"}
        }
      }",
      types.issue_detail_decoder(),
    )
  detail.description |> should.equal([])
}

// adf: recursive tree decode, tested against the real shapes captured from
// the site (doc → paragraph → text; doc → bulletList → listItem → paragraph)

pub fn decode_empty_doc_test() {
  let assert Ok(node) =
    parse(
      "{\"type\": \"doc\", \"version\": 1, \"content\": []}",
      adf.adf_decoder(),
    )
  node.kind |> should.equal("doc")
  node.content |> should.equal([])
}

pub fn decode_adf_tree_test() {
  let assert Ok(node) =
    parse(
      "{
        \"content\": [
          {
            \"type\": \"paragraph\",
            \"content\": [
              {\"type\": \"text\", \"text\": \"Documentation includes:\"}
            ]
          },
          {
            \"type\": \"bulletList\",
            \"content\": [
              {
                \"type\": \"listItem\",
                \"content\": [
                  {
                    \"type\": \"paragraph\",
                    \"content\": [{\"type\": \"text\", \"text\": \"User manuals.\"}]
                  }
                ]
              }
            ]
          }
        ],
        \"type\": \"doc\",
        \"version\": 1
      }",
      adf.adf_decoder(),
    )
  let assert [paragraph, bullet_list] = node.content
  paragraph.kind |> should.equal("paragraph")
  let assert [text] = paragraph.content
  text.text |> should.equal("Documentation includes:")
  bullet_list.kind |> should.equal("bulletList")
  let assert [list_item] = bullet_list.content
  let assert [item_paragraph] = list_item.content
  let assert [item_text] = item_paragraph.content
  item_text.text |> should.equal("User manuals.")
}

pub fn decode_adf_link_mark_test() {
  let assert Ok(node) =
    parse(
      "{
        \"type\": \"paragraph\",
        \"content\": [
          {
            \"type\": \"text\",
            \"text\": \"click\",
            \"marks\": [{\"type\": \"link\", \"attrs\": {\"href\": \"https://x\"}}]
          }
        ]
      }",
      adf.adf_decoder(),
    )
  let assert [text] = node.content
  let assert [mark] = text.marks
  mark.kind |> should.equal("link")
  mark.href |> should.equal("https://x")
}

// a decoded + re-encoded issue survives the app-shape round trip
// (this is the shape /jira/search serves and the frontend / cache readers
// decode)

pub fn issue_json_round_trip_test() {
  let issue =
    types.Issue(
      key: "SAM1-10",
      id: "10009",
      summary: "Finalize Documentation for the Project",
      status: types.Status("In Review", "indeterminate"),
      assignee: Some(types.User(
        "557058:abc",
        "Jeff Merckens",
        "https://x/48.png",
      )),
      labels: ["docs", "urgent"],
      updated: "2026-10-18T18:05:18.418-0400",
    )
  let response =
    json.object([#("issues", json.array([issue], types.issue_to_json))])
    |> json.to_string
  let assert Ok([decoded]) = parse(response, types.issues_response_decoder())
  decoded |> should.equal(issue)
}
