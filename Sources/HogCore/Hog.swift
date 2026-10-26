/// Shared entry points and constants for the hog core library.
public enum Hog {
    /// Version of hog. Bumped on release.
    public static let version = "0.2.0-dev"

    /// Schema identifier of the JSON snapshot (see docs/architecture/design-vi.md, section 4).
    public static let snapshotSchema = "hog.snapshot/1"
}
