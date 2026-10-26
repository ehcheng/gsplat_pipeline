// Patches the stock SuperSplat viewer bundle before it is copied into dist/3d/<slug>/.
//
// Why: the stock GamepadDevice turns the camera at orbitSpeed (18 deg/s) scaled by fov/120,
// i.e. about 9 deg/s at the default 60 deg FOV, and walks at the keyboard's un-boosted 4
// units/s with no sprint, no dead zone and a linear stick response. Console shooters turn at
// roughly 100 to 250 deg/s at full deflection (Halo CE default ~114 deg/s rising to ~234 deg/s
// with look acceleration; Borderlands ~90 to 135 deg/s; Apex ALC defaults are in the same
// range), with a radial dead zone and a curved response so small deflections stay precise.
//
// The replacement below (the whole `class GamepadDevice`) gives the sticks that behaviour:
//   right stick  look (FPS convention, stick forward looks up; the Invert Y-Axis setting flips it): yawSpeed/pitchSpeed deg/s
//                at full deflection at referenceFov, scaled by
//                the current FOV so on-screen speed stays constant; Halo-style look
//                acceleration adds extraYaw/extraPitch after rampUpTime at near-full deflection
//   left stick   move: keyboard base speed x moveGain
//   L3 or RT     sprint (same multiplier as Shift on the keyboard: x2 walk, x4 fly)
//   LT           precision (same as Ctrl: x0.5 walk, x0.25 fly)
//   RB / LB      fly up / down (fly mode)
//   A            jump (walk mode)
// Tunables live at the top of the class.
//
// It also adds a user-facing "Invert Y-Axis" switch to the viewer's settings panel (the gear),
// below the stock toggles. Default off; the choice is kept in localStorage ('invertLook') like
// the stock settings. It flips vertical look for the gamepad right stick in every mode and for
// the mouse in Fly and Walk. Orbit drag and touch are direct manipulation and stay as they are.
//
// AR/VR (options.xr): the stock viewer shows "Enter AR" / "Enter VR" whenever the browser
// offers a WebXR session. The full 1.5 M splat scenes are not usable in a headset or a phone's
// AR session, so the main build (`xr: false`) reports both as unavailable and the buttons never
// appear. The /vr build (`xr: true`) keeps them and starts the session with a reduced XR
// framebuffer (options.xrFramebufferScale, the biggest fill-rate lever on Quest 3, where every
// splat still blends at full resolution per eye). See scripts/build-viewer.mjs.
//
// Orbit by default: every device starts in Orbit around the opening camera's target, like
// 4dv.ai (drag orbits the subject, two fingers or right-drag pan, pinch or wheel zooms, tap
// re-centres), which suits mouse-only visitors. Stock started our scenes in Fly. Any of
// W/A/S/D/Q/E/I/J/K/L (and the arrows) switch to Fly. The idle intro animation stays the stock
// figure-8 wiggle.
//
// Keyboard look: I/J/K/L turn the view, so the keyboard alone can fly two-handed, W/A/S/D +
// Q/E on the left hand and I/J/K/L on the right. The help panel lists them. See KEY_LOOK below.
//
// Quest's browser identifies as Linux, not Android, so the viewer treats it as a desktop and
// renders the 2D page at full resolution with the desktop splat budget. Both builds default
// Quest's Quality slider to Performance instead (the user can still move it). Stock 1.38 does
// detect Quest for XR sessions (full foveation, 72 Hz, 0.8 framebuffer at Performance); the
// /vr build overrides those with the values below.
//
// Orbit zoom, for pinch, wheel and trackpad pinch alike (z is a frame's zoom delta; D is the
// opening orbit distance, the scene's scale):
//   - exponential, distance x e^z, at distances above ZOOM_SPEED_FLOOR x D. Stock PlayCanvas
//     uses distance x (1 + z): zooming in and back out by the same amount leaves the camera
//     closer ((1 + z)(1 - z) = 1 - z^2), and a fast pinch-in (z <= -1 in one frame, about 150 px
//     of finger travel) pins the distance at its 0.01 floor.
//   - below that, steps sized as if at ZOOM_SPEED_FLOOR x D, so zoom near the orbit centre
//     neither crawls nor needs as many pinch-outs as there were pinch-ins.
//   - zoom-in stops at ZOOM_MIN x D; pinches past it are dropped, so one pinch-out leaves.
// For small z at normal distances this matches stock, so wheel and slow pinch feel unchanged.
//
// `node scripts/viewer-patch.mjs` re-patches every scene already in dist/3d (main and /vr) from
// the pristine bundle in node_modules, and re-renders each index.html from the viewer's current
// template, keeping the page's title, base href, content URL and opening camera (then deploy).
// The page must follow the bundle: 1.38 builds its UI in script, so markup from older
// templates no longer matches.

import { existsSync, readdirSync, readFileSync, statSync, writeFileSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { renderViewerHtml } from '@playcanvas/supersplat-viewer';
import { defaultSettings } from '@playcanvas/supersplat-viewer/settings';

const GAMEPAD_DEVICE = String.raw`// ---- user-facing "Invert Y-Axis" setting (see scripts/viewer-patch.mjs) ----
const lookSettings = {
    invertY: (() => {
        try {
            return localStorage.getItem('invertLook') === 'true';
        }
        catch {
            return false;
        }
    })()
};
// Adds the switch to the settings panel, styled like the stock rows (.settingsRow/.toggleSwitch).
const installInvertLookSetting = () => {
    if (typeof document === 'undefined' || document.getElementById('invertLookRow')) {
        return;
    }
    const anchor = document.getElementById('annotationsRow');
    if (!anchor) {
        return;
    }
    const row = document.createElement('div');
    row.id = 'invertLookRow';
    row.className = 'settingsRow';
    row.title = 'Flip up/down look for gamepad, and for the mouse in Fly and Walk';
    row.innerHTML = '<div id="invertLookOption">Invert Y-Axis</div><div id="invertLookCheck" class="toggleSwitch"><div class="toggleTrack"><div class="toggleThumb"></div></div></div>';
    const check = row.lastElementChild;
    const sync = () => check.classList.toggle('active', lookSettings.invertY);
    row.addEventListener('click', () => {
        lookSettings.invertY = !lookSettings.invertY;
        try {
            localStorage.setItem('invertLook', String(lookSettings.invertY));
        }
        catch { /* private mode: the setting lasts for this page only */ }
        sync();
    });
    sync();
    anchor.after(row);
};
// Lists the I/J/K/L keyboard look in the help panel under every desktop "W,S,A,D" row (Fly and
// Walk; in Orbit the keys switch to Fly). Rows copy the stock .control-item markup.
const installKeyLookHelp = () => {
    if (typeof document === 'undefined' || document.querySelector('[data-keylook]')) {
        return;
    }
    const addRow = (after, action) => {
        const row = document.createElement('div');
        row.className = 'control-item';
        row.dataset.keylook = '';
        row.innerHTML = '<span class="control-action"></span><span class="control-key">I,J,K,L</span>';
        row.firstElementChild.textContent = action;
        after.after(row);
    };
    const panel = document.getElementById('desktopInfoPanel');
    if (!panel) {
        return;
    }
    for (const key of panel.querySelectorAll('.control-key')) {
        if (key.textContent.trim() === 'W,S,A,D') {
            addRow(key.closest('.control-item'), 'Look Around');
        }
    }
};
class GamepadDevice {
    // ---- FPS-style gamepad tuning (see scripts/viewer-patch.mjs) ----
    moveSpeed = 4;                  // keyboard base, units/s (kept for API compatibility)
    moveGain = 1.5;                 // full left stick = moveSpeed * moveGain units/s
    orbitSpeed = 18;                // stock field, unused by this implementation
    gamepadRotateSensitivity = 1.0; // user multiplier on all look rates
    yawSpeed = 126;                 // deg/s at full right-stick deflection at referenceFov (180 x 0.7, tuned 2026-09-18)
    pitchSpeed = 95;                // deg/s (0.75 x yaw, the usual console ratio)
    extraYaw = 56;                  // look acceleration: extra deg/s once ramped
    extraPitch = 42;
    rampUpTime = 0.5;               // seconds at near-full deflection to reach the extra speed
    rampThreshold = 0.9;            // shaped stick magnitude that counts as "full"
    referenceFov = 90;              // rates above apply at this vertical FOV; scaled by fov/referenceFov
    orbitLookGain = 0.6;            // orbit mode uses yaw/pitch * this (no FOV scaling)
    deadzone = 0.12;                // radial inner dead zone (Xbox sticks idle at up to ~0.1)
    outerThreshold = 0.98;          // magnitude treated as full deflection
    responseCurve = 1.5;            // 1 = linear, 2 = squared; classic console curves sit between
    // true = flight/drone convention (stick forward pitches down); false = FPS default.
    // Driven by the user's "Invert Y-Axis" setting.
    get invertLook() {
        return lookSettings.invertY;
    }
    _source = new GamepadSource();
    _global = null;
    _ramp = 0;
    _left = [0, 0];
    _right = [0, 0];
    attach(_canvas, global) {
        this._global = global;
        installInvertLookSetting();
        // GamepadSource polls navigator.getGamepads() — no DOM attach needed.
    }
    detach() {
        this._global = null;
    }
    _shape(x, y, out) {
        const len = Math.hypot(x, y);
        if (!(len > this.deadzone)) {
            out[0] = 0;
            out[1] = 0;
            return out;
        }
        const t = Math.min(1, (len - this.deadzone) / Math.max(1e-6, this.outerThreshold - this.deadzone));
        const s = Math.pow(t, this.responseCurve) / len;
        out[0] = x * s;
        out[1] = y * s;
        return out;
    }
    _pad() {
        const pads = typeof navigator !== 'undefined' && navigator.getGamepads ? navigator.getGamepads() : [];
        for (let i = 0; i < pads.length; i++) {
            const gp = pads[i];
            if (gp && gp.mapping === 'standard' && gp.buttons.length >= 12) {
                return gp;
            }
        }
        return null;
    }
    update(ctx, frame) {
        // as stock: the gamepad belongs to the page, so only the instance the host enables reads it
        if (!this._global?.state.inputEnabled)
            return;
        const { dt, cameraComponent, isFly, isWalk, isFirstPerson, mode } = ctx;
        const { leftStick, rightStick } = this._source.read();
        const [mx, my] = this._shape(leftStick[0], leftStick[1], this._left);
        const [rx, ry] = this._shape(rightStick[0], rightStick[1], this._right);
        const gp = this._pad();
        const held = (i) => {
            const b = gp && gp.buttons[i];
            return b ? (b.pressed || b.value > 0.5 ? 1 : 0) : 0;
        };
        const sprint = held(10) || held(7);
        const slow = held(6);
        const up = held(5);
        const down = held(4);
        const jump = held(0);
        const active = mx !== 0 || my !== 0 || rx !== 0 || ry !== 0 || sprint || up || down || jump;
        if (isFly && active) {
            this._global?.events.fire('navigateCancel');
        }
        const { deltas } = frame;
        // move: left stick, with Shift/Ctrl-equivalent multipliers on the sprint/precision buttons
        const mul = sprint ? (isWalk ? 2 : 4) : slow ? (isWalk ? 0.5 : 0.25) : 1;
        const speed = this.moveSpeed * this.moveGain * mul;
        const v = tmpV$3.set(mx * speed * dt, 0, -my * speed * dt);
        if (isFly) {
            v.y = (up - down) * speed * dt;
        }
        else if (isWalk) {
            // WalkController treats move[1] > 0 as the jump trigger.
            v.y = jump ? 1 : 0;
        }
        deltas.move.append([v.x, v.y, flipZForOrbit(mode, v.z)]);
        // look: right stick in deg/s, FOV-scaled in first person, with look acceleration
        const lookMag = Math.hypot(rx, ry);
        this._ramp = lookMag >= this.rampThreshold ? Math.min(1, this._ramp + dt / Math.max(1e-3, this.rampUpTime)) : 0;
        const fovScale = isFirstPerson ? cameraComponent.fov / this.referenceFov : this.orbitLookGain;
        const yaw = (this.yawSpeed + this.extraYaw * this._ramp) * fovScale * this.gamepadRotateSensitivity;
        const pitch = (this.pitchSpeed + this.extraPitch * this._ramp) * fovScale * this.gamepadRotateSensitivity;
        deltas.rotate.append([rx * yaw * dt, (this.invertLook ? -ry : ry) * pitch * dt, 0]);
    }
}`;

// KEY_LOOK: I/J/K/L turn the view like a digital right stick, so the keyboard alone can fly
// two-handed (W/A/S/D + Q/E move, I/J/K/L look). J/L yaw, I/K pitch (I looks up; the Invert
// Y-Axis setting flips it). FOV scaling and orbit gain as the gamepad's right stick, without its
// look acceleration, at 0.6 x its rates: the user found the full rates too twitchy and wants a
// strafe key plus a turn key held together to circle the subject. At the default 60 degree FOV
// that is 50 deg/s, which circles a point ~4.6 units away at fly speed (4 units/s), a little
// beyond a typical capture radius. Each axis is a smoothed rate that glides: it eases in from
// rest (time constant keyLookEaseIn) and coasts out after release (keyLookEaseOut), so a tap
// is a soft nudge and nothing steps (a ramp that started at 35% of full rate felt jittery on
// I/K). Shift turns faster along with running. Like W/A/S/D, pressing one switches Orbit to
// Fly (and on desktop turns on gaming controls), so keyboard means first person; the orbit
// gain only matters if a key is held across a mode change. No Ctrl modifier: Ctrl+I/J/K/L
// are browser shortcuts.
const KEY_LOOK_FIELDS = `    // ---- I/J/K/L keyboard look (scripts/viewer-patch.mjs) ----
    keyYawSpeed = 75;           // deg/s at keyLookReferenceFov: 0.6 x the gamepad's full right stick (tuned 2026-10-16: 126, then 88, then 75)
    keyPitchSpeed = 57;         // 0.6 x the gamepad's 95
    keyLookReferenceFov = 90;
    keyLookOrbitGain = 0.6;     // Orbit: no FOV scaling, as the gamepad
    keyLookShift = 1.5;         // Shift multiplier
    keyLookEaseIn = 0.2;        // time constant (s) toward full rate while held (~95% at 0.6 s)
    keyLookEaseOut = 0.12;      // time constant (s) back to rest after release
    _lookAxis = [0, 0];
    _lookRate = [0, 0];         // smoothed yaw/pitch rates, deg/s before FOV scaling
`;
const KEY_LOOK_ACCUMULATE = `        this._lookAxis[0] += key[keyCode.L] - key[keyCode.J];
        this._lookAxis[1] += key[keyCode.K] - key[keyCode.I];
`;
const KEY_LOOK_APPLY = `        // I/J/K/L look with glide (scripts/viewer-patch.mjs)
        const lookX = Math.sign(this._lookAxis[0]);
        const lookY = Math.sign(this._lookAxis[1]);
        if (isFly && (lookX !== 0 || lookY !== 0)) {
            events.fire('navigateCancel');
        }
        const lookTarget = [lookX * this.keyYawSpeed, (lookSettings.invertY ? -lookY : lookY) * this.keyPitchSpeed];
        for (let i = 0; i < 2; i++) {
            const held = i === 0 ? lookX : lookY;
            const tau = held !== 0 ? this.keyLookEaseIn : this.keyLookEaseOut;
            this._lookRate[i] += (lookTarget[i] - this._lookRate[i]) * (1 - Math.exp(-dt / tau));
            if (held === 0 && Math.abs(this._lookRate[i]) < 0.05) {
                this._lookRate[i] = 0;
            }
        }
        const lookScale = (isFirstPerson ? cameraComponent.fov / this.keyLookReferenceFov : this.keyLookOrbitGain) * (this._shift ? this.keyLookShift : 1) * dt;
        v.x += this._lookRate[0] * lookScale;
        v.y += this._lookRate[1] * lookScale;
`;

// xrFarClip: the stock viewer clips XR sessions at 1000 units, and frame.mjs parks far splats
// on a shell at 300 x capture radius (about 1000 units on a typical scene, up to 1.25 x that),
// so in a headset the sky and far hills could be cut off. 4000 keeps every shell inside.
// xrFixedFoveation: WebXR fixed foveated rendering level 0..1 on the XR layer (Quest shades the
// periphery at lower density; nearly free, the stock viewer leaves it off). Level 1 showed a
// visible coarse patch at the nasal edge of the left eye on Quest 3; 0.5 does not. xrFrameRate: the
// session frame rate to request when the headset offers it (Quest 3's browser can run 90 Hz;
// 72 Hz gives every frame 25% more time). 0 leaves either one at the browser default.
// xrSortEpsilon: the WebGL path sorts every splat on a worker whenever the camera moves more
// than 1e-3 units or 1e-3 in direction (0.06 degrees), which a head in a headset does every
// frame. 0.01 (1 cm, 0.6 degrees) re-sorts only on real motion; the order error at that
// scale is invisible.
export const XR_DEFAULTS = Object.freeze({ xr: false, xrFramebufferScale: 0.7, xrFarClip: 4000, xrFixedFoveation: 0.5, xrFrameRate: 72, xrSortEpsilon: 0.01 });

const replaceOnce = (source, needle, replacement) => {
  if (source.split(needle).length !== 2) {
    throw new Error(`viewer-patch: expected exactly one occurrence of "${needle.trim()}" in the viewer bundle; update scripts/viewer-patch.mjs.`);
  }
  return source.replace(needle, () => replacement);
};

export function patchViewerBundle(source, options = {}) {
  const { xr, xrFramebufferScale, xrFarClip, xrFixedFoveation, xrFrameRate, xrSortEpsilon } = { ...XR_DEFAULTS, ...options };
  if (!(xrSortEpsilon >= 1e-3 && xrSortEpsilon <= 0.1)) throw new Error('viewer-patch: xrSortEpsilon must be in [0.001, 0.1]');
  if (!(xrFramebufferScale > 0 && xrFramebufferScale <= 1)) throw new Error('viewer-patch: xrFramebufferScale must be in (0, 1]');
  if (!(xrFarClip >= 1000)) throw new Error('viewer-patch: xrFarClip must be >= 1000');
  if (!(xrFixedFoveation >= 0 && xrFixedFoveation <= 1)) throw new Error('viewer-patch: xrFixedFoveation must be in [0, 1]');
  if (!(xrFrameRate === 0 || (xrFrameRate >= 60 && xrFrameRate <= 120))) throw new Error('viewer-patch: xrFrameRate must be 0 or 60..120');
  const pattern = /\nclass GamepadDevice \{[\s\S]*?\n\}\n/g;
  const matches = source.match(pattern) ?? [];
  if (matches.length !== 1) {
    throw new Error(`viewer-patch: expected exactly one GamepadDevice class in the viewer bundle, found ${matches.length}. The @playcanvas/supersplat-viewer layout changed; update scripts/viewer-patch.mjs.`);
  }
  for (const needle of ['const flipZForOrbit = ', 'class GamepadSource extends InputSource', 'const tmpV$3 = new Vec3();']) {
    if (!source.includes(needle)) throw new Error(`viewer-patch: the viewer bundle no longer defines "${needle}"; update scripts/viewer-patch.mjs.`);
  }
  if (source.indexOf('const flipZForOrbit = ') > source.indexOf('\nclass GamepadDevice {')) {
    throw new Error('viewer-patch: flipZForOrbit is defined after GamepadDevice; update scripts/viewer-patch.mjs.');
  }
  // Mouse look honours "Invert Y-Axis" in first person (Fly/Walk). KeyboardMouseDevice is
  // defined after GamepadDevice, so lookSettings is initialised before it runs.
  const mouseLook = '        mouseRotate.set(mouse[0], mouse[1], 0);\n';
  if (source.split(mouseLook).length !== 2) {
    throw new Error('viewer-patch: expected exactly one KeyboardMouseDevice mouseRotate.set(...) line; update scripts/viewer-patch.mjs.');
  }
  if (source.indexOf(mouseLook) < source.indexOf('\nclass GamepadDevice {')) {
    throw new Error('viewer-patch: KeyboardMouseDevice now precedes GamepadDevice; update scripts/viewer-patch.mjs.');
  }
  let patched = source
    .replace(pattern, () => `\n${GAMEPAD_DEVICE}\n`)
    .replace(mouseLook, () => '        mouseRotate.set(mouse[0], (isFirstPerson && lookSettings.invertY ? -1 : 1) * mouse[1], 0);\n');

  // Every device starts in Orbit around the opening camera's target (drag orbits, two fingers or
  // right-drag pan, pinch or wheel zooms, tap re-centres). Stock picks Orbit only when the
  // opening camera is outside the scene bounds, which never holds for our scenes (frame.mjs
  // keeps a far shell), so they started in Fly, where a drag turns the head in place. The idle
  // animation is untouched: isObjectExperience still selects it, so scenes keep the figure-8
  // wiggle (not the turntable an object experience gets).
  patched = replaceOnce(
    patched,
    "        state.cameraMode = state.hasAnimation ? 'anim' : isObjectExperience ? 'orbit' : walkAllowed ? 'walk' : 'fly';\n",
    "        state.cameraMode = state.hasAnimation ? 'anim' : 'orbit'; // Orbit by default (scripts/viewer-patch.mjs)\n"
  );
  patched = replaceOnce(
    patched,
    "        const defaultMode = () => (isObjectExperience ? 'orbit' : walkAllowed ? 'walk' : 'fly');\n",
    "        const defaultMode = () => 'orbit'; // Orbit by default (scripts/viewer-patch.mjs)\n"
  );
  patched = replaceOnce(
    patched,
    "        let preWalkMode = isObjectExperience ? 'orbit' : 'fly';\n",
    "        let preWalkMode = 'orbit'; // Orbit by default (scripts/viewer-patch.mjs)\n"
  );

  // Keyboard look on I/J/K/L, the right-hand mirror of W/A/S/D (see KEY_LOOK above).
  patched = replaceOnce(patched, '    _ctrl = 0;\n    _jump = 0;\n', '    _ctrl = 0;\n    _jump = 0;\n' + KEY_LOOK_FIELDS);
  patched = replaceOnce(patched, '        this._ctrl += key[keyCode.CTRL];\n', '        this._ctrl += key[keyCode.CTRL];\n' + KEY_LOOK_ACCUMULATE);
  const mouseRotateAdd = '        v.add(mouseRotate.mulScalar((1 - pan) * this.orbitSpeed * orbitFactor * this.mouseRotateSensitivity * DISPLACEMENT_SCALE));\n';
  patched = replaceOnce(patched, mouseRotateAdd, mouseRotateAdd + KEY_LOOK_APPLY);
  const keyboardMeta = '        patchKeyboardMeta(this._source, () => global.state.inputEnabled);\n';
  patched = replaceOnce(patched, keyboardMeta, keyboardMeta + '        installKeyLookHelp();\n');
  // I/J/K/L switch to Fly like W/A/S/D: on desktop the mode shortcut also turns on gaming
  // controls (mouse look), and the device requests first person as Q/E and the arrows do.
  patched = replaceOnce(
    patched,
    "const isWasdKey = (event) => event.code === 'KeyW' || event.code === 'KeyA' || event.code === 'KeyS' || event.code === 'KeyD';\n",
    "const isWasdKey = (event) => event.code === 'KeyW' || event.code === 'KeyA' || event.code === 'KeyS' || event.code === 'KeyD' ||\n" +
      "    event.code === 'KeyI' || event.code === 'KeyJ' || event.code === 'KeyK' || event.code === 'KeyL'; // I/J/K/L look (scripts/viewer-patch.mjs)\n"
  );
  patched = replaceOnce(
    patched,
    '        if (!isFirstPerson && this._axis.length() > 0) {\n',
    '        if (!isFirstPerson && (this._axis.length() > 0 || this._lookAxis[0] !== 0 || this._lookAxis[1] !== 0)) {\n'
  );

  // Orbit zoom (see the header): pinch, wheel and trackpad all pass through here.
  const ZOOM_MIN = 0.02;
  const ZOOM_SPEED_FLOOR = 0.25;
  patched = replaceOnce(
    patched,
    '\t\tthis._targetChildPose.move(offset$3.set(0, 0, dist * (1 + move[2]) - dist));\n',
    '\t\t// Zoom scaled to the opening orbit distance (scripts/viewer-patch.mjs).\n' +
      '\t\tconst zoomRef = this._zoomRef ??= dist;\n' +
      `\t\tconst zoomed = Math.max(Math.min(dist, ${ZOOM_MIN} * zoomRef), dist + Math.max(dist, ${ZOOM_SPEED_FLOOR} * zoomRef) * Math.expm1(move[2]));\n` +
      '\t\tthis._targetChildPose.move(offset$3.set(0, 0, zoomed - dist));\n'
  );

  // Quest browser: default the Quality slider to Performance (the mobile canvas scale and splat
  // budget). Stock treats Quest as a desktop because its browser reports one.
  patched = replaceOnce(
    patched,
    '    const preferences = readPreferences(platform.mobile);\n',
    "    const preferences = readPreferences(platform.mobile || /OculusBrowser|\\bQuest\\b/u.test(navigator.userAgent)); // Quest: Performance (scripts/viewer-patch.mjs)\n"
  );

  const hasAR = '        state.hasAR = state.canStartAR || webglAR;\n';
  const hasVR = '        state.hasVR = state.canStartVR || webglVR;\n';
  const xrScale = '                    framebufferScaleFactor: quality.xrFramebufferScale,\n';
  // Stock (1.38+) gives standalone headsets full foveation and 72 Hz, and a 0.8 framebuffer at
  // Performance quality; the /vr build replaces those with the values tuned on a Quest 3.
  const xrSessionTuning =
    '        if (quality.xrFixedFoveation)\n            xr.fixedFoveation = 1;\n' +
    '        const frameRate = quality.xrTargetFrameRate;\n' +
    '        if (frameRate !== null && xr.supportedFrameRates?.includes(frameRate))\n            xr.updateTargetFrameRate(frameRate);\n';
  const xrParamFn =
    "(name, fallback) => { const p = new URL(location.href).searchParams; const v = Number(p.get(name)); return p.has(name) && Number.isFinite(v) ? v : fallback; }";
  if (xr) {
    // Keep the AR/VR buttons; render the XR session at a reduced framebuffer scale.
    // Runtime overrides for in-headset testing: ?fbscale=0.8&foveation=0&hz=90 on the /vr URL.
    patched = replaceOnce(
      patched,
      xrScale,
      `                    framebufferScaleFactor: Math.min(1.5, Math.max(0.3, (${xrParamFn})('fbscale', ${xrFramebufferScale}))), // (scripts/viewer-patch.mjs)\n`
    );
    patched = replaceOnce(patched, '        camera.camera.farClip = 1000;\n', `        camera.camera.farClip = ${xrFarClip}; // far shell must stay inside (scripts/viewer-patch.mjs)\n`);
    // Sort worker (its function body is serialised into the worker, so editing the source works).
    patched = replaceOnce(
      patched,
      '\t\tconst epsilon = 1e-3;\n\t\tif (!forceUpdate && Math.abs(px - lastCameraPosition.x)',
      `\t\tconst epsilon = ${xrSortEpsilon}; // re-sort threshold for headsets (scripts/viewer-patch.mjs)\n\t\tif (!forceUpdate && Math.abs(px - lastCameraPosition.x)`
    );
    // Once the session runs: fixed foveation on the layer and a lower session frame rate.
    patched = replaceOnce(
      patched,
      xrSessionTuning,
      '        // Quest performance levers (scripts/viewer-patch.mjs)\n' +
        `        const xrParam = ${xrParamFn};\n` +
        `        try { xr.fixedFoveation = Math.min(1, Math.max(0, xrParam('foveation', ${xrFixedFoveation}))); } catch { /* layer without foveation */ }\n` +
        `        try { const fr = xrParam('hz', ${xrFrameRate}); const rates = xr.supportedFrameRates; if (fr > 0 && rates && rates.includes(fr)) xr.updateTargetFrameRate(fr); } catch { /* not supported */ }\n`
    );
  } else {
    // Main build: no AR/VR. The /vr build of the same scene carries them.
    patched = replaceOnce(patched, hasAR, '        state.hasAR = false; // AR is offered by the /vr build only (scripts/viewer-patch.mjs)\n');
    patched = replaceOnce(patched, hasVR, '        state.hasVR = false; // VR is offered by the /vr build only (scripts/viewer-patch.mjs)\n');
  }
  return patched;
}

// The page around the bundle. The /vr page (xr) starts on WebGL: WebXR sessions cannot run on
// the viewer's WebGPU device (no XRGPUBinding in Quest's browser, nor in Chrome on Android), so
// the stock page would load on WebGPU and then ask to reload on WebGL at the AR/VR button.
export function viewerPage({ baseHref, title, contentUrl = './scene.sog', camera = null, xr = false }) {
  const settings = defaultSettings('object');
  if (camera) settings.cameras = [{ initial: camera }];
  const html = renderViewerHtml({
    bootstrap: { contentUrl, settings },
    baseHref,
    backgroundColor: [0.025, 0.025, 0.03],
    headExtras: [
      '<meta name="robots" content="noindex,nofollow,noarchive,nosnippet">',
      '<meta name="color-scheme" content="dark">'
    ].join(''),
    inlineCss: true
  }).replace('<title>SuperSplat Viewer</title>', () => `<title>${title}</title>`);
  if (!xr) return html;
  const rendererPick = "url.searchParams.has('webgl') ? 'webgl' : 'webgpu'";
  if (html.split(rendererPick).length !== 2) throw new Error('viewer-patch: the viewer HTML no longer picks its renderer with the expected expression; update scripts/viewer-patch.mjs.');
  return html.replace(rendererPick, () => "'webgl' /* XR needs WebGL; see scripts/viewer-patch.mjs */");
}

// Reads back what viewerPage was given from a built page (any template version since the
// sse-bootstrap block).
const readPage = (file) => {
  const html = readFileSync(file, 'utf8');
  const bootstrap = html.match(/<script type="application\/json" id="sse-bootstrap">([\s\S]*?)<\/script>/);
  const baseHref = html.match(/<base href="([^"]*)">/);
  const title = html.match(/<title>([^<]*)<\/title>/);
  if (!bootstrap || !baseHref || !title) throw new Error(`viewer-patch: ${file} has no sse-bootstrap block, base href or title; rebuild it with build-viewer.mjs.`);
  const { contentUrl, settings } = JSON.parse(bootstrap[1]);
  return { baseHref: baseHref[1], title: title[1], contentUrl, camera: settings?.cameras?.[0]?.initial ?? null };
};

// CLI: re-patch every built scene from the pristine bundle.
if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  const project = resolve(dirname(fileURLToPath(import.meta.url)), '..');
  const bundle = join(project, 'node_modules', '@playcanvas', 'supersplat-viewer', 'public', 'index.js');
  const pristine = readFileSync(bundle, 'utf8');
  const main = patchViewerBundle(pristine, { xr: false });
  const root = join(project, 'dist', '3d');
  const scenes = existsSync(root) ? readdirSync(root).filter((name) => statSync(join(root, name)).isDirectory() && existsSync(join(root, name, 'index.html'))) : [];
  for (const scene of scenes) {
    writeFileSync(join(root, scene, 'index.html'), viewerPage(readPage(join(root, scene, 'index.html'))));
    writeFileSync(join(root, scene, 'index.js'), main);
    console.log(`patched dist/3d/${scene}/index.{html,js} (${(main.length / 1048576).toFixed(2)} MiB, no AR/VR)`);
    const vrDir = join(root, scene, 'vr');
    if (existsSync(join(vrDir, 'index.html'))) {
      writeFileSync(join(vrDir, 'index.html'), viewerPage({ ...readPage(join(vrDir, 'index.html')), xr: true }));
      // The /vr build records its framebuffer scale in build.json so a re-patch keeps it.
      const buildJson = join(vrDir, 'build.json');
      const built = existsSync(buildJson) ? JSON.parse(readFileSync(buildJson, 'utf8')).vr ?? {} : {};
      const opts = { xr: true };
      for (const key of ['xrFramebufferScale', 'xrFarClip', 'xrFixedFoveation', 'xrFrameRate', 'xrSortEpsilon']) if (built[key] !== undefined) opts[key] = built[key];
      const effective = { ...XR_DEFAULTS, ...opts };
      writeFileSync(join(vrDir, 'index.js'), patchViewerBundle(pristine, opts));
      console.log(`patched dist/3d/${scene}/vr/index.{html,js} (AR/VR, framebuffer x${effective.xrFramebufferScale}, far clip ${effective.xrFarClip}, foveation ${effective.xrFixedFoveation}, ${effective.xrFrameRate || 'default'} Hz)`);
    }
  }
  if (scenes.length === 0) console.log('no built scenes under dist/3d');
}
