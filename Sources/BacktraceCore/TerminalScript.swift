import Foundation

public enum TerminalScript {
    public static func appleString(_ text: String) -> String {
        "\"" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"").replacingOccurrences(of: "\n", with: "\\n").replacingOccurrences(of: "\r", with: "\\r") + "\""
    }
    public static func iTerm(command: String) -> String {
        """
        tell application id "com.googlecode.iterm2"
            if (count of windows) > 0 then
                tell current window
                    create tab with default profile command \(appleString(command))
                end tell
            else
                create window with default profile command \(appleString(command))
            end if
            activate
        end tell
        """
    }
}
