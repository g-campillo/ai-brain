import ArgumentParser

@main
struct Brain: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "brain",
        abstract: "Persistent knowledge base for Claude — MCP server, hooks, and admin tools.",
        subcommands: []
    )
}
