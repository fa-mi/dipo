import SwiftUI

// MARK: - Motion
//
// Four curves for the whole app, and a rule about when NOT to animate.
//
// The point of restraint here is not taste, it is meaning. When everything
// moves, movement stops carrying information: the user cannot tell the
// difference between a number that changed because they did something and a
// number that changed because the view redrew. Animation is a signal, and a
// signal used everywhere is noise.
//
// So: motion marks a CHANGE THE USER CAUSED. A tap, a swipe, a value they just
// edited. Content merely appearing on screen does not need to be announced —
// staggered fade-ins on every card are the thing that makes an app feel slow
// even when it is fast, because the user is waiting for a reveal they did not
// ask for.
enum AppMotion {

    /// Taps, toggles, selection. Short enough to feel like a response rather
    /// than a transition.
    static let tap = Animation.easeOut(duration: 0.18)

    /// Something moving into or out of place — a row changing lists, a section
    /// expanding. Spring, because position changes read as physical.
    static let move = Animation.spring(response: 0.34, dampingFraction: 0.86)

    /// A figure recomputing. Slower and softer: the user should notice it
    /// settled, not watch it travel.
    static let figure = Animation.easeInOut(duration: 0.28)

    /// Content arriving for the first time. Deliberately the plainest of the
    /// four and deliberately NOT staggered — a list that reveals itself row by
    /// row makes the reader wait to read.
    static let appear = Animation.easeOut(duration: 0.22)
}
