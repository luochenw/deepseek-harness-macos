import Foundation

/// Domain state owned by one controller. Swift extensions cannot add stored
/// properties, so each domain keeps its private state class here, one instance
/// per type, and it lives exactly as long as the controller.
@MainActor
final class DSHControllerStateBag {
  private var states: [ObjectIdentifier: AnyObject] = [:]

  func state<State: AnyObject>(_ make: () -> State) -> State {
    let key = ObjectIdentifier(State.self)
    if let state = states[key] as? State { return state }
    let state = make()
    states[key] = state
    return state
  }
}
