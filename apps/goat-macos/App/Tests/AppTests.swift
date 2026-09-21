import Testing

/// Host tests share app state. Serialization applies recursively to every domain.
@Suite(.serialized)
struct AppTests {
    @Suite struct App {}
    @Suite struct Bleet {}
    @Suite struct Caprine {}
    @Suite struct Shepherd {}
    @Suite struct Inference {}
    @Suite struct GOATed {}
    @Suite struct Herd {}
    @Suite struct Hindsight {}
    @Suite struct Memory {}
    @Suite struct MCPClient {}
    @Suite struct Pens {}
    @Suite struct Persistence {}
    @Suite struct Hoofprint {}
    @Suite struct Paddock {}
}
