import Common

struct DynamicTiling: Withable {
    var enabled = false
    var maxWindows = 3
    var minimumWindowWidth = 560
    var appMinimumWidths: [String: Int] = [:]
}

private let dynamicTilingParser: [String: any ParserProtocol<DynamicTiling>] = [
    "enabled": Parser(\.enabled, parseBool),
    "max-windows": Parser(\.maxWindows, { raw, backtrace in
        parseInt(raw, backtrace).flatMap { value in
            (1 ... 3).contains(value) ? .success(value) : .failure(.init(backtrace, "max-windows must be between 1 and 3"))
        }
    }),
    "minimum-window-width": Parser(\.minimumWindowWidth, { raw, backtrace in
        parseInt(raw, backtrace).flatMap { value in
            value > 0 ? .success(value) : .failure(.init(backtrace, "minimum-window-width must be positive"))
        }
    }),
    "app-minimum-widths": Parser(\.appMinimumWidths, parseAppMinimumWidths),
]

private func parseAppMinimumWidths(_ raw: OrderedJson, _ backtrace: ConfigBacktrace) -> ResOrConfigParseDiagnostic<[String: Int]> {
    guard let table = raw.asDictOrNil else { return .failure(.init(backtrace, "Expected an app bundle ID to minimum width table")) }
    var result: [String: Int] = [:]
    for (app, value) in table {
        guard let width = value.asIntOrNil, width > 0 else { return .failure(.init(backtrace, "App minimum widths must be positive integers")) }
        result[app] = width
    }
    return .success(result)
}

func parseDynamicTiling(_ raw: OrderedJson, _ backtrace: ConfigBacktrace, _ context: inout ConfigParserContext) -> DynamicTiling {
    parseNonEmptyTable(raw, DynamicTiling(), dynamicTilingParser, backtrace, &context)
}

