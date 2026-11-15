import Common

struct DynamicTiling: Withable {
    var enabled = false
    var maxWindows = 4
    var minimumWindowWidth = 560
    var minimumWindowHeight = 320
    var appMinimumWidths: [String: Int] = [:]
    var appMinimumHeights: [String: Int] = [:]
}

private let dynamicTilingParser: [String: any ParserProtocol<DynamicTiling>] = [
    "enabled": Parser(\.enabled, parseBool),
    "max-windows": Parser(\.maxWindows, { raw, backtrace in
        parseInt(raw, backtrace).flatMap { value in
            (1 ... 4).contains(value) ? .success(value) : .failure(.init(backtrace, "max-windows must be between 1 and 4"))
        }
    }),
    "minimum-window-width": Parser(\.minimumWindowWidth, { raw, backtrace in
        parseInt(raw, backtrace).flatMap { value in
            value > 0 ? .success(value) : .failure(.init(backtrace, "minimum-window-width must be positive"))
        }
    }),
    "minimum-window-height": Parser(\.minimumWindowHeight, { raw, backtrace in
        parseInt(raw, backtrace).flatMap { value in
            value > 0 ? .success(value) : .failure(.init(backtrace, "minimum-window-height must be positive"))
        }
    }),
    "app-minimum-heights": Parser(\.appMinimumHeights, parseAppMinimumSizes),
    "app-minimum-widths": Parser(\.appMinimumWidths, parseAppMinimumSizes),
]

private func parseAppMinimumSizes(_ raw: OrderedJson, _ backtrace: ConfigBacktrace) -> ResOrConfigParseDiagnostic<[String: Int]> {
    guard let table = raw.asDictOrNil else { return .failure(.init(backtrace, "Expected an app bundle ID to minimum size table")) }
    var result: [String: Int] = [:]
    for (app, value) in table {
        guard let width = value.asIntOrNil, width > 0 else { return .failure(.init(backtrace, "App minimum sizes must be positive integers")) }
        result[app] = width
    }
    return .success(result)
}

func parseDynamicTiling(_ raw: OrderedJson, _ backtrace: ConfigBacktrace, _ context: inout ConfigParserContext) -> DynamicTiling {
    parseNonEmptyTable(raw, DynamicTiling(), dynamicTilingParser, backtrace, &context)
}
