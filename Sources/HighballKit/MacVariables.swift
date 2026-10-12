import Foundation

/// Values a recipe writes that depend on the Mac a launch runs on, filled in at each launch.
/// `${memoryMB}` is this Mac's memory in MB and `${memoryMB*0.375}` a share of it, rounded down.
/// A game that sizes its streaming from the video memory DXGI reports fills what it is told it
/// has, and on Apple silicon that memory is the Mac's own: Microsoft Flight Simulator 2024 through
/// vkd3d-proton took 27 to 33 GB of a 32 GB M4 at the Ultra preset it picked, and 12 to 14 GB with
/// DXVK's dxgi.maxVideoMemoryBudget at 12288 MB and the Low-End preset (measured together on
/// 2026-10-12, so the budget's own share is not known).
/// Variables and dxvk.conf values are expanded when a launch builds them, so a recipe keeps the
/// formula and each Mac gets its own number. Anything else between ${ and } stays as written.
public enum MacVariables {
    public static func expand(_ value: String, memoryMB: Int = Machine.memoryMB) -> String {
        guard value.contains("${") else { return value }
        return value.replacing(#/\$\{memoryMB(?:\*([0-9]+(?:\.[0-9]+)?))?\}/#) { match in
            let factor = match.1.flatMap { Double($0) } ?? 1
            return String(Int((Double(memoryMB) * factor).rounded(.down)))
        }
    }
}
