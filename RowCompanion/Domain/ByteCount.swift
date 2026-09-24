import Foundation

/// Non-UI byte-count formatting so error copy stays testable off-device and
/// pure (no PDFKit/UIKit dependency). Shared by the PDF import errors and
/// the backup format errors.
public enum ByteCount {
    public enum Format {
        public static func mebibytes(_ bytes: Int) -> String {
            let mib = Double(bytes) / (1024 * 1024)
            return mib >= 1
                ? String(format: "%.1f MiB", mib)
                : String(format: "%.0f KiB", Double(bytes) / 1024)
        }
    }
}
