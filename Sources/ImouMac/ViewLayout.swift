import AppKit

extension NSView {
    /// Pins all four edges to `parent` without adding it as a subview (for views a container already owns).
    func pinEdges(to parent: NSView) {
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            leadingAnchor.constraint(equalTo: parent.leadingAnchor), trailingAnchor.constraint(equalTo: parent.trailingAnchor),
            topAnchor.constraint(equalTo: parent.topAnchor), bottomAnchor.constraint(equalTo: parent.bottomAnchor)
        ])
    }

    /// Adds `child` filling this view, optionally below `sibling` (nil puts it beneath everything).
    func addFilling(_ child: NSView, below sibling: NSView? = nil) {
        addSubview(child, positioned: .below, relativeTo: sibling)
        child.pinEdges(to: self)
    }
}
