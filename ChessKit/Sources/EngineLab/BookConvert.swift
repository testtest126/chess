import ChessProtocol

/// Converts an `OpeningBook.init(compactRows:)` file (UCI-prefix rows) into
/// the `OpeningBook.init(keyedRows:)` format `OpeningBook.large` actually
/// loads. Pure and testable: runs the existing, validated `compactRows`
/// loader exactly once — the same legality checks and `repetitionKey`
/// hashing it's always used — then exports the resulting book, so there's no
/// second implementation of book-building logic to drift out of sync.
public enum BookConvert {
    public static func convert(compactRows: [String]) -> [String] {
        OpeningBook(compactRows: compactRows).exportKeyedRows()
    }
}
