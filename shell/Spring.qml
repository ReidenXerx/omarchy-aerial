import QtQuick

// What moves the overview: a spring, all the way through.
//
// While the fingers are down the spring chases them rather than being nailed
// to them — a few milliseconds behind, settling with a small overshoot when
// they stop — which is what makes a swipe feel like it has weight instead of
// like a scrollbar. When they lift, the same spring simply gets a new target
// and carries on at the speed it already had, so there is no seam between
// following the hand and finishing on its own, and it lands with a little
// bounce.
FrameAnimation {
  id: spring

  property real value: 0
  property real velocity: 0          // per second
  property real target: 0

  // How quickly it pulls toward the target, in radians per second, and how
  // much it resists overshooting: 1 never overshoots, lower bounces more.
  property real stiffness: 18
  property real damping: 0.72

  // Never below this: an overview that bounced past closed would draw every
  // card bigger than its window.
  property real floor: -Infinity

  signal settled()

  /** Chase `to`, keeping whatever position and speed there already is. */
  function follow(to) {
    spring.target = to
    if (!spring.running) spring.start()
  }

  /** Start from `from` at `speed`, heading for `to`. */
  function launch(from, to, speed) {
    spring.value = from
    spring.velocity = speed || 0
    spring.target = to
    if (spring.isSettled()) {
      spring.finish()
      return
    }
    if (!spring.running) spring.start()
  }

  /** Stop where it is, keeping its speed for whoever picks it up next. */
  function hold() { spring.stop() }

  function isSettled() {
    return Math.abs(spring.value - spring.target) < 0.0008 && Math.abs(spring.velocity) < 0.02
  }

  // Settled is said while still running, so anything that hands the position
  // over to something else does it before anyone sees the animation as done.
  function finish() {
    spring.value = spring.target
    spring.velocity = 0
    spring.settled()
    spring.stop()
  }

  onTriggered: {
    // Small fixed steps, so a dropped frame does not become a jump.
    let left = Math.min(spring.frameTime, 1 / 30)
    const w = spring.stiffness
    const z = spring.damping
    const to = spring.target
    let x = spring.value
    let v = spring.velocity
    while (left > 0) {
      const dt = Math.min(left, 1 / 240)
      const a = -w * w * (x - to) - 2 * z * w * v
      v += a * dt
      x += v * dt
      left -= dt
    }
    if (x < spring.floor) {
      x = spring.floor
      v = 0
    }
    spring.velocity = v
    spring.value = x
    if (spring.isSettled()) spring.finish()
  }
}
