import Foundation
import os

/// Unified logging facility for PangolinGit.
public enum PangolinLog {
    private static let subsystem = "be.macbit.pangolingit"
    
    public static let general = Logger(subsystem: subsystem, category: "General")
    public static let git = Logger(subsystem: subsystem, category: "Git")
    public static let cache = Logger(subsystem: subsystem, category: "Cache")
    public static let finder = Logger(subsystem: subsystem, category: "FinderSync")
    public static let xpc = Logger(subsystem: subsystem, category: "XPC")
}
