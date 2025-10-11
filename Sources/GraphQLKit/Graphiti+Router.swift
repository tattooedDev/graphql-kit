import Graphiti
import GraphQL
import Vapor

extension Schema: @retroactive @unchecked Sendable {}

public extension RoutesBuilder {
    func register<RootType>(
        graphQLSchema schema: Schema<RootType, Request>,
        withResolver rootAPI: RootType,
        at path: PathComponent = "graphql",
        postBodyStreamStrategy: HTTPBodyStreamStrategy = .collect
    ) {
        on(.POST, path, body: postBodyStreamStrategy) { request async throws -> Response in
            let result = try await request.resolveByBody(graphQLSchema: schema, with: rootAPI)

            return try await result.encodeResponse(status: .ok, for: request)
        }
        get(path) { request async throws -> Response in
            let result = try await request.resolveByQueryParameters(graphQLSchema: schema, with: rootAPI)

            return try await result.encodeResponse(status: .ok, for: request)
        }
    }
}

enum GraphQLResolveError: Swift.Error {
    case noQueryFound
}

extension GraphQLResult: @retroactive Content {
    public func encodeResponse(for _: Request) async throws -> Response {
        try Response(
            status: .ok,
            headers: [
                "Content-Type": "application/json",
            ],
            body: .init(data: GraphQLJSONEncoder().encode(self))
        )
    }
}
