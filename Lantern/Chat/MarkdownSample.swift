#if DEBUG
import Foundation

/// `-markdownSample [full|partial]`: every answer shows this instead of its own text, for checking
/// how the transcript draws Markdown without a model. `partial` cuts it off inside a code block,
/// the way a streaming reply looks between ticks.
enum MarkdownSample {
    static var override: String? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let i = arguments.firstIndex(of: "-markdownSample") else { return nil }
        let mode = arguments.indices.contains(i + 1) ? arguments[i + 1] : "full"
        if mode == "partial", let cut = text.range(of: "    return sorted") {
            return String(text[..<cut.lowerBound]) + "    ret"
        }
        return text
    }

    static let text = """
    # Sorting in Swift

    Swift's `sorted()` returns a **new array**, while `sort()` works *in place*. See [the docs](https://developer.apple.com/documentation/swift/array) for more.

    ## A quick example

    ```swift
    func topScores(_ scores: [Int], count: Int = 3) -> [Int] {
        let sorted = scores.sorted(by: >)
        return sorted.prefix(count).map { $0 } // a much longer line that has to go somewhere when the screen is narrow
    }
    ```

    ### Things to keep in mind

    1. Sorting is **O(n log n)**.
    2. It's stable since Swift 5:
       - equal elements keep their order
       - so you can sort by one key, then another
    3. Use `sort(by:)` for custom orders.

    > Tip: if you only need the largest few, a heap or `max()` is cheaper than sorting everything.
    > It also uses less memory.

    | Method | In place | Returns |
    |:-------|:--------:|--------:|
    | `sort()` | Yes | Nothing |
    | `sorted()` | No | A new array |

    ---

    That's it. Ask again if you want ~~more~~ examples in other languages:

    ```
    plain text block
    ```

    9. A step with two paragraphs.

       Its second paragraph has no marker of its own.
    10. A step with code:

        ```sh
        swift build
        ```
    11. Done.
    """
}
#endif
