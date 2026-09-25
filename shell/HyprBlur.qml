import QtQuick

// Hyprland's own blur, run on an item.
//
// The overview has to hand each window over to its card without the frosted
// glass behind it changing, so it blurs exactly the way the compositor does:
// the same dual-Kawase passes, the same offsets, vibrancy, noise, contrast and
// brightness, at the monitor's real pixel size, fed Hyprland's own settings.
// See shell/blur/*.frag, each a port of the shader Hyprland 0.56 uses.
//
// Hyprland draws every level into one monitor-sized buffer; here each level
// is its own texture half the size of the one before, which samples the same
// pixels. Up to four passes (Hyprland allows eight; past four the difference
// is invisible and not worth the textures).
//
// `output` is the result, a texture the size of the monitor, never drawn
// itself: cards sample the part of it they are over.
Item {
  id: blur

  property Item sourceItem: null
  // Physical pixels, which is what Hyprland blurs in.
  property size pixelSize: Qt.size(1, 1)
  property bool live: true

  property real size: 8
  property int passes: 1
  property real noise: 0
  property real contrast: 1
  property real brightness: 1
  property real vibrancy: 0
  property real vibrancyDarkness: 0

  readonly property Item output: finished

  readonly property int levels: Math.max(1, Math.min(4, blur.passes))

  function level(k) {
    const scale = Math.pow(2, k)
    return Qt.size(Math.max(1, Math.ceil(blur.pixelSize.width / scale)),
                   Math.max(1, Math.ceil(blur.pixelSize.height / scale)))
  }
  function texelOf(k) {
    const s = blur.level(k)
    return Qt.vector2d(1 / s.width, 1 / s.height)
  }

  // Everything below is drawn only into textures. Each stage is an effect,
  // captured by the texture after it with `hideSource`, so none of it ever
  // reaches the screen. The textures are kept "visible" at zero opacity: a
  // hidden one is never brought up to date.

  ShaderEffectSource {
    id: captured
    width: 1; height: 1; opacity: 0
    sourceItem: blur.sourceItem
    textureSize: blur.level(0)
    live: blur.live
    smooth: true
  }

  // Contrast and brightness first, as Hyprland does — skipped when they are
  // left alone, since then it changes nothing.
  readonly property bool adjusting: blur.contrast !== 1 || blur.brightness > 1

  ShaderEffect {
    id: prepareEffect
    width: blur.width; height: blur.height
    property var source: captured
    property real contrast: blur.contrast
    property real brightness: blur.brightness
    fragmentShader: Qt.resolvedUrl("blur/prepare.frag.qsb")
  }
  ShaderEffectSource {
    id: prepared
    width: 1; height: 1; opacity: 0
    sourceItem: prepareEffect
    hideSource: true
    textureSize: blur.level(0)
    live: blur.live && blur.adjusting
    smooth: true
  }

  readonly property var start: blur.adjusting ? prepared : captured

  // ------------------------------------------------------------------- down

  component Down: ShaderEffect {
    required property int step
    width: blur.width; height: blur.height
    property vector2d texel: blur.texelOf(step - 1)
    property real radius: blur.size
    property real passes: blur.levels
    property real vibrancy: blur.vibrancy
    property real vibrancyDarkness: blur.vibrancyDarkness
    fragmentShader: Qt.resolvedUrl("blur/down.frag.qsb")
  }

  component Level: ShaderEffectSource {
    required property int step
    required property bool used
    width: 1; height: 1; opacity: 0
    hideSource: true
    textureSize: blur.level(step)
    live: blur.live && used
    smooth: true
  }

  Down { id: d1; step: 1; property var source: blur.start }
  Level { id: d1t; step: 1; used: blur.levels >= 1; sourceItem: d1 }
  Down { id: d2; step: 2; property var source: d1t }
  Level { id: d2t; step: 2; used: blur.levels >= 2; sourceItem: d2 }
  Down { id: d3; step: 3; property var source: d2t }
  Level { id: d3t; step: 3; used: blur.levels >= 3; sourceItem: d3 }
  Down { id: d4; step: 4; property var source: d3t }
  Level { id: d4t; step: 4; used: blur.levels >= 4; sourceItem: d4 }

  // --------------------------------------------------------------------- up
  // Back up one level at a time. The first step up reads the bottom of the
  // way down; every one after reads the step before it.

  component Up: ShaderEffect {
    required property int step          // the level this writes
    width: blur.width; height: blur.height
    property vector2d texel: blur.texelOf(step + 1)
    property real radius: blur.size
    fragmentShader: Qt.resolvedUrl("blur/up.frag.qsb")
  }

  Up { id: u3; step: 3; property var source: d4t }
  Level { id: u3t; step: 3; used: blur.levels >= 4; sourceItem: u3 }
  Up { id: u2; step: 2; property var source: blur.levels === 3 ? d3t : u3t }
  Level { id: u2t; step: 2; used: blur.levels >= 3; sourceItem: u2 }
  Up { id: u1; step: 1; property var source: blur.levels === 2 ? d2t : u2t }
  Level { id: u1t; step: 1; used: blur.levels >= 2; sourceItem: u1 }
  Up { id: u0; step: 0; property var source: blur.levels === 1 ? d1t : u1t }
  Level { id: u0t; step: 0; used: true; sourceItem: u0 }

  // ----------------------------------------------------------------- finish

  ShaderEffect {
    id: finishEffect
    width: blur.width; height: blur.height
    property var source: u0t
    property real noise: blur.noise
    property real brightness: blur.brightness
    fragmentShader: Qt.resolvedUrl("blur/finish.frag.qsb")
  }
  ShaderEffectSource {
    id: finished
    width: 1; height: 1; opacity: 0
    sourceItem: finishEffect
    hideSource: true
    textureSize: blur.level(0)
    live: blur.live
    smooth: true
  }
}
