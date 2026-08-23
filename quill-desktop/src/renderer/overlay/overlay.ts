import type { OverlayState } from '../../core/contracts';

/// The HUD's renderer. Small on purpose: it draws four states and nothing else,
/// and every decision about *which* state belongs to the coordinator.

declare global {
  interface Window {
    quillOverlay: {
      onState(handler: (state: OverlayState) => void): void;
      /// Reports how wide the pill wants to be, so the main process can size the
      /// window once rather than the window resizing mid-animation.
      reportWidth(width: number): void;
    };
  }
}

const pill = document.getElementById('pill') as HTMLDivElement;
const wave = document.getElementById('wave') as HTMLDivElement;
const insertedLabel = document.getElementById('insertedLabel') as HTMLSpanElement;
const errorLabel = document.getElementById('errorLabel') as HTMLSpanElement;

/// Nine bars, which is what fits in a 148-point pill at a 3-point bar and a
/// 3-point gap without the ends touching the radius. An odd count so there is a
/// centre one for the tallest reading to land on.
const BAR_COUNT = 9;
const bars: HTMLElement[] = [];
for (let index = 0; index < BAR_COUNT; index += 1) {
  const bar = document.createElement('i');
  wave.appendChild(bar);
  bars.push(bar);
}

/// A short trail of recent levels, so the waveform reads as a signal travelling
/// through the pill rather than nine bars all doing the same thing. Each frame
/// the newest level is pushed on the left and the rest shift right, which is
/// the direction text runs and therefore the one that reads as "still going".
const trail = new Array<number>(BAR_COUNT).fill(0);

/// The gap between the floor of the bar and the ceiling. Below 3 the bar is a
/// dot; above 20 it touches the pill's radius.
const MIN_BAR = 3;
const MAX_BAR = 20;

let level = 0;
let smoothed = 0;
let animating = false;

function frame(): void {
  if (!animating) return;
  // A fast attack and a slow release. The attack is what makes it feel
  // connected to the voice; the release is what stops it flickering to zero
  // between syllables and reading as though the microphone cut out.
  const target = Math.min(1, level * 2.6);
  smoothed += (target - smoothed) * (target > smoothed ? 0.55 : 0.14);
  trail.pop();
  trail.unshift(smoothed);
  for (let index = 0; index < BAR_COUNT; index += 1) {
    // Bars away from the leading edge are damped, so the shape tapers instead
    // of ending in a cliff.
    const damping = 1 - (index / BAR_COUNT) * 0.45;
    const value = (trail[index] ?? 0) * damping;
    const height = MIN_BAR + value * (MAX_BAR - MIN_BAR);
    bars[index]!.style.height = `${height.toFixed(1)}px`;
    bars[index]!.style.opacity = String(0.45 + value * 0.55);
  }
  requestAnimationFrame(frame);
}

function startAnimating(): void {
  if (animating) return;
  animating = true;
  requestAnimationFrame(frame);
}

function stopAnimating(): void {
  animating = false;
}

function apply(state: OverlayState): void {
  switch (state.kind) {
    case 'hidden':
      pill.classList.remove('visible');
      stopAnimating();
      return;
    case 'listening':
      level = state.level;
      if (pill.dataset.state !== 'listening') {
        pill.dataset.state = 'listening';
        trail.fill(0);
        smoothed = 0;
      }
      startAnimating();
      break;
    case 'transcribing':
      stopAnimating();
      pill.dataset.state = 'transcribing';
      break;
    case 'inserted':
      stopAnimating();
      insertedLabel.textContent = state.words === 1 ? '1 word' : `${state.words} words`;
      // Restart the tick's draw-in even when the state was already `inserted`
      // — two dictations in a row should both animate.
      pill.dataset.state = '';
      void pill.offsetWidth;
      pill.dataset.state = 'inserted';
      break;
    case 'error':
      stopAnimating();
      errorLabel.textContent = state.message;
      pill.dataset.state = 'error';
      break;
  }
  pill.classList.add('visible');
  // Measured after the state class has been applied, so the width reported is
  // the width of the content that is now visible.
  requestAnimationFrame(() => {
    window.quillOverlay.reportWidth(Math.ceil(pill.getBoundingClientRect().width));
  });
}

window.quillOverlay.onState(apply);
