import Testing
import VaporTesting
import Vapor
@testable import GraphQLKit

@Suite
struct GraphQLKitTests {
    private func withApp(_ test: (Application) async throws -> ()) async throws {
        let app = try await Application.make(.testing)
        try await test(app)
        try await app.asyncShutdown()
    }
    
    struct SomeBearerAuthenticator: AsyncBearerAuthenticator {
        struct User: Authenticatable {}
        
        func authenticate(bearer: BearerAuthorization, for request: Request) async throws {
            // Bearer token should be equal to `token` to pass the auth
            if bearer.token == "token" {
                request.auth.login(User())
            } else {
                throw Abort(.unauthorized)
            }
        }
        
        func authenticate(request: Request) async throws {
            // Bearer token should be equal to `token` to pass the auth
            if request.headers.bearerAuthorization?.token == "token" {
                request.auth.login(User())
            } else {
                throw Abort(.unauthorized)
            }
        }
    }
    
    struct Address: Content {
        public var number: Int
        public var streetName: String
        public var additionalStreetName: String?
        public var city: String
        public var postalCode: String
        public var country: String
    }
    
    struct Person: Content {
        public var firstName: String
        public var lastName: String
        public var age: UInt
        public var address: Address
    }
    
    
    struct ProtectedResolver {
        func test(store: Request, _: NoArguments) throws -> String {
            _ = try store.auth.require(SomeBearerAuthenticator.User.self)
            return "Hello World"
        }
        
        func number(store: Request, _: NoArguments) throws -> Int {
            _ = try store.auth.require(SomeBearerAuthenticator.User.self)
            return 42
        }
    }
    
    struct Resolver {
        func test(store: Request, _: NoArguments) -> String {
            "Hello World"
        }
        
        func number(store: Request, _: NoArguments) -> Int {
            42
        }
        
        func person(store: Request, _: NoArguments) throws -> Person {
            return Person(
                firstName: "John",
                lastName: "Appleseed",
                age: 42,
                address: Address(
                    number: 767,
                    streetName: "Fifth Avenue",
                    city: "New York",
                    postalCode: "NY 10153",
                    country: "United States"
                )
            )
        }
    }
    
    let protectedSchema = try! Schema<ProtectedResolver, Request> {
        Query {
            Field("test", at: ProtectedResolver.test)
            Field("number", at: ProtectedResolver.number)
        }
    }
    
    let schema = try! Schema<Resolver, Request> {
        Scalar(UInt.self)
        
        Type(Address.self) {
            Field("additionalStreetName", at: \Address.additionalStreetName)
            Field("city", at: \Address.city)
            Field("country", at: \Address.country)
            Field("number", at: \Address.number)
            Field("postalCode", at: \Address.postalCode)
            Field("streetName", at: \Address.streetName)
        }
        
        Type(Person.self) {
            Field("address", at: \Person.address)
            Field("age", at: \Person.age)
            Field("firstName", at: \Person.firstName)
            Field("lastName", at: \Person.lastName)
        }
        
        Query {
            Field("test", at: Resolver.test)
            Field("number", at: Resolver.number)
            Field("person", at: Resolver.person)
        }
    }
    
    let query = """
            query {
                test
            }
            """
    
    @Test
    func testPostEndpoint() async throws {
        let queryRequest = QueryRequest(query: query, operationName: nil, variables: nil)
        let data = String(data: try! JSONEncoder().encode(queryRequest), encoding: .utf8)!
        
        try await withApp { app in
            app.register(graphQLSchema: schema, withResolver: Resolver())
            
            var body = ByteBufferAllocator().buffer(capacity: 0)
            body.writeString(data)
            var headers = HTTPHeaders()
            headers.replaceOrAdd(name: .contentLength, value: body.readableBytes.description)
            headers.contentType = .json
            
            try await app.testing().test(.POST, "/graphql", headers: headers, body: body) { res in
                #expect(res.status == .ok)
                var res = res
                let expected = #"{"data":{"test":"Hello World"}}"#
                #expect(res.body.readString(length: expected.count) == expected)
            }
        }
    }
    
    @Test
    func testGetEndpoint() async throws {
        try await withApp { app in
            app.register(graphQLSchema: schema, withResolver: Resolver())
            try await app.testing().test(.GET, "/graphql?query=\(query.addingPercentEncoding(withAllowedCharacters: .alphanumerics)!)") { res in
                #expect(res.status == .ok)
                var body = res.body
                let expected = #"{"data":{"test":"Hello World"}}"#
                #expect(body.readString(length: expected.count) == expected)
            }
        }
    }
    
    @Test
    func testPostOperationName() async throws {
        let multiQuery = """
        query World {
            test
        }
        
        query Number {
            number
        }
        """
        
        let queryRequest = QueryRequest(query: multiQuery, operationName: "Number", variables: nil)
        let data = String(data: try! JSONEncoder().encode(queryRequest), encoding: .utf8)!
        
        try await withApp { app in
            app.register(graphQLSchema: schema, withResolver: Resolver())
            
            var body = ByteBufferAllocator().buffer(capacity: 0)
            body.writeString(data)
            var headers = HTTPHeaders()
            headers.replaceOrAdd(name: .contentLength, value: body.readableBytes.description)
            headers.contentType = .json
            
            try await app.testing().test(.POST, "/graphql", headers: headers, body: body) { res in
                #expect(res.status == .ok)
                var res = res
                let expected = #"{"data":{"number":42}}"#
                #expect(res.body.readString(length: expected.count) == expected)
            }
        }
    }
    
    @Test
    func testProtectedPostEndpoint() async throws {
        let queryRequest = QueryRequest(query: query, operationName: nil, variables: nil)
        let data = String(data: try! JSONEncoder().encode(queryRequest), encoding: .utf8)!
        
        try await withApp { app in
            let protected = app.grouped(SomeBearerAuthenticator())
            protected.register(graphQLSchema: protectedSchema, withResolver: ProtectedResolver())
            
            var body = ByteBufferAllocator().buffer(capacity: 0)
            body.writeString(data)
            var headers = HTTPHeaders()
            headers.replaceOrAdd(name: .contentLength, value: body.readableBytes.description)
            headers.contentType = .json
            
            var protectedHeaders = headers
            protectedHeaders.replaceOrAdd(name: .authorization, value: "Bearer token")
            
            try await app.testing().test(.POST, "/graphql", headers: headers, body: body) { res in
                #expect(res.status == .unauthorized)
            }
            
            try await app.testing().test(.POST, "/graphql", headers: protectedHeaders, body: body) { res in
                #expect(res.status == .ok)
                var res = res
                let expected = #"{"data":{"test":"Hello World"}}"#
                #expect(res.body.readString(length: expected.count) == expected)
            }
        }
    }
    
    @Test
    func testProtectedGetEndpoint() async throws {
        try await withApp { app in
            let protected = app.grouped(SomeBearerAuthenticator())
            protected.register(graphQLSchema: protectedSchema, withResolver: ProtectedResolver())
            
            var headers = HTTPHeaders()
            headers.replaceOrAdd(name: .authorization, value: "Bearer token")
            
            try await app.testing().test(.GET, "/graphql?query=\(query.addingPercentEncoding(withAllowedCharacters: .alphanumerics)!)") { res in
                #expect(res.status == .unauthorized)
            }
            
            try await app.testing().test(.GET, "/graphql?query=\(query.addingPercentEncoding(withAllowedCharacters: .alphanumerics)!)", headers: headers) { res in
                #expect(res.status == .ok)
                var body = res.body
                let expected = #"{"data":{"test":"Hello World"}}"#
                #expect(body.readString(length: expected.count) == expected)
            }
        }
    }
    
    @Test
    func testProtectedPostOperatinName() async throws {
        let multiQuery = """
        query World {
            test
        }
        
        query Number {
            number
        }
        """
        
        let queryRequest = QueryRequest(query: multiQuery, operationName: "Number", variables: nil)
        let data = String(data: try! JSONEncoder().encode(queryRequest), encoding: .utf8)!
        
        try await withApp { app in
            let protected = app.grouped(SomeBearerAuthenticator())
            protected.register(graphQLSchema: protectedSchema, withResolver: ProtectedResolver())
            
            var body = ByteBufferAllocator().buffer(capacity: 0)
            body.writeString(data)
            
            var headers = HTTPHeaders()
            headers.replaceOrAdd(name: .contentLength, value: body.readableBytes.description)
            headers.contentType = .json
            
            var protectedHeaders = headers
            protectedHeaders.replaceOrAdd(name: .authorization, value: "Bearer token")
            
            try await app.testing().test(.POST, "/graphql", headers: headers, body: body) { res in
                #expect(res.status == .unauthorized)
            }
            
            try await app.testing().test(.POST, "/graphql", headers: protectedHeaders, body: body) { res in
                #expect(res.status == .ok)
                var res = res
                let expected = #"{"data":{"number":42}}"#
                #expect(res.body.readString(length: expected.count) == expected)
            }
        }
    }
    
    @Test
    func testFieldsOrder() async throws {
        let query1Request = QueryRequest(query: // this query returns fields in arbitrary order
                                    """
                                    query {
                                        person {
                                            firstName
                                            lastName
                                            age
                                            address {
                                                number
                                                streetName
                                                city
                                                postalCode
                                                country
                                            }
                                        }
                                    }
                                    """, operationName: nil, variables: nil)
        let query2Request = QueryRequest(query: // this query will return all fields in alphabetical order
                                    """
                                    query {
                                        person {
                                            address {
                                                city
                                                country
                                                number
                                                postalCode
                                                streetName
                                            }
                                            age
                                            firstName
                                            lastName
                                        }
                                    }
                                    """, operationName: nil, variables: nil)
        let data1 = String(data: try! JSONEncoder().encode(query1Request), encoding: .utf8)!
        let data2 = String(data: try! JSONEncoder().encode(query2Request), encoding: .utf8)!
        
        try await withApp { app in
            app.register(graphQLSchema: schema, withResolver: Resolver())
            
            var body1 = ByteBufferAllocator().buffer(capacity: 0)
            body1.writeString(data1)
            var headers1 = HTTPHeaders()
            headers1.replaceOrAdd(name: .contentLength, value: body1.readableBytes.description)
            headers1.contentType = .json
            
            var body2 = ByteBufferAllocator().buffer(capacity: 0)
            body2.writeString(data2)
            var headers2 = HTTPHeaders()
            headers2.replaceOrAdd(name: .contentLength, value: body2.readableBytes.description)
            headers2.contentType = .json
            
            try await app.testing().test(.POST, "/graphql", headers: headers1, body: body1) { res in
                #expect(res.status == .ok)
                var res = res
                let expected = #"{"data":{"person":{"firstName":"John","lastName":"Appleseed","age":42,"address":{"number":767,"streetName":"Fifth Avenue","city":"New York","postalCode":"NY 10153","country":"United States"}}}}"#
                #expect(res.body.readString(length: expected.count) == expected)
            }
            
            try await app.testing().test(.POST, "/graphql", headers: headers2, body: body2) { res in
                #expect(res.status == .ok)
                var res = res
                let expected = #"{"data":{"person":{"address":{"city":"New York","country":"United States","number":767,"postalCode":"NY 10153","streetName":"Fifth Avenue"},"age":42,"firstName":"John","lastName":"Appleseed"}}}"#
                #expect(res.body.readString(length: expected.count) == expected)
            }
        }
    }
    
    @Test
    func testEnum() async throws {
        enum TodoState: String, Codable, CaseIterable {
            case open
            case done
            case forLater
        }
        
        final class TestResolver: Sendable {
            init() {}
            func test(store: Request, _: NoArguments) -> TodoState {
                .open
            }
        }
        
        
        let schema = try Schema<TestResolver, Request> {
            Enum(TodoState.self)
            Query {
                Field("test", at: TestResolver.test)
            }
        }
        
        let query = """
        query {
            test
        }
        """
        
        try await withApp { app in
            app.register(graphQLSchema: schema, withResolver: TestResolver())
            try await app.testing().test(.GET, "/graphql?query=\(query.addingPercentEncoding(withAllowedCharacters: .alphanumerics)!)") { res in
                #expect(res.status == .ok)
                var body = res.body
                let expected = #"{"data":{"test":"open"}}"#
                #expect(body.readString(length: expected.count) == expected)
            }
        }
    }
}
