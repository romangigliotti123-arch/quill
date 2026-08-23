/// One line at the bottom of the window that says what just happened.
///
/// Every mutating action on every screen calls this. An app that changes
/// something and shows nothing is an app whose buttons feel dead — and the
/// alternative, a dialog per confirmation, is worse for exactly the actions
/// that happen most often.

let timer: number | null = null;

export function toast(message: string): void {
  const element = document.getElementById('toast');
  if (!element) return;
  element.textContent = message;
  element.classList.add('visible');
  if (timer !== null) window.clearTimeout(timer);
  timer = window.setTimeout(() => {
    element.classList.remove('visible');
    timer = null;
  }, 2600);
}
