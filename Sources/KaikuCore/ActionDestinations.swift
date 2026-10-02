import Foundation

/// Requests and responses of the services action items are sent to.
extension ActionItems {
    /// Things URL scheme command that adds the item.
    public static func thingsURL(_ item: ActionItem, notes: String) -> URL? {
        var query = [("title", item.text), ("notes", notes)]
        if let due = validDay(item.due) { query.append(("deadline", due)) }
        let encoded = query.map { "\($0.0)=\(percentEncode($0.1))" }.joined(separator: "&")
        return URL(string: "things:///add?" + encoded)
    }

    public static let linearEndpoint = URL(string: "https://api.linear.app/graphql")!

    /// GraphQL body that creates a Linear issue.
    public static func linearIssueBody(teamID: String, projectID: String?, item: ActionItem, description: String) throws -> Data {
        var input: [String: Any] = ["teamId": teamID, "title": item.text, "description": description]
        if let projectID, !projectID.isEmpty { input["projectId"] = projectID }
        if let due = validDay(item.due) { input["dueDate"] = due }
        return try JSONSerialization.data(withJSONObject: [
            "query": "mutation($input: IssueCreateInput!) { issueCreate(input: $input) { success issue { identifier url } } }",
            "variables": ["input": input],
        ] as [String: Any])
    }

    public static let linearTeamsBody = Data(#"{"query":"{ teams { nodes { id name } } }"}"#.utf8)

    public static func linearProjectsBody(teamID: String) throws -> Data {
        try JSONSerialization.data(withJSONObject: [
            "query": "query($id: String!) { team(id: $id) { projects { nodes { id name } } } }",
            "variables": ["id": teamID],
        ] as [String: Any])
    }

    /// A Linear team or project to pick in Settings.
    public struct LinearChoice: Identifiable, Equatable, Sendable {
        public let id: String
        public let name: String
    }

    private struct Nodes: Decodable {
        struct Node: Decodable { let id: String; let name: String }
        let nodes: [Node]
    }

    private struct LinearReply: Decodable {
        struct Err: Decodable { let message: String }
        struct Payload: Decodable {
            struct Team: Decodable { let projects: Nodes }
            struct Created: Decodable { let success: Bool }
            let teams: Nodes?
            let team: Team?
            let issueCreate: Created?
        }
        let data: Payload?
        let errors: [Err]?
    }

    private static func linearReply(_ data: Data) throws -> LinearReply.Payload {
        let reply: LinearReply
        do { reply = try JSONDecoder().decode(LinearReply.self, from: data) }
        catch { throw ParseError.invalid("Linear JSON: \(error)") }
        if let message = reply.errors?.first?.message { throw ParseError.invalid("Linear: \(message)") }
        guard let payload = reply.data else { throw ParseError.invalid("Linear returned no data") }
        return payload
    }

    public static func parseLinearTeams(_ data: Data) throws -> [LinearChoice] {
        try linearReply(data).teams?.nodes.map { LinearChoice(id: $0.id, name: $0.name) } ?? []
    }

    public static func parseLinearProjects(_ data: Data) throws -> [LinearChoice] {
        try linearReply(data).team?.projects.nodes.map { LinearChoice(id: $0.id, name: $0.name) } ?? []
    }

    /// Throws unless Linear reports the issue as created.
    public static func checkLinearCreated(_ data: Data) throws {
        guard try linearReply(data).issueCreate?.success == true else {
            throw ParseError.invalid("Linear did not create the issue")
        }
    }

    private static func percentEncode(_ s: String) -> String {
        let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        return s.addingPercentEncoding(withAllowedCharacters: unreserved) ?? ""
    }
}
