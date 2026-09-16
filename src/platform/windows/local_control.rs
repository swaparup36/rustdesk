use std::{
    collections::VecDeque,
    io, ptr,
    sync::atomic::{AtomicBool, AtomicU64, AtomicUsize, Ordering},
    time::{Duration, Instant},
};
use winapi::um::{libloaderapi::GetModuleHandleExA, winuser::*};

static ACTIVE_SESSIONS: AtomicUsize = AtomicUsize::new(0);
static PAUSED: AtomicBool = AtomicBool::new(false);
static REVISION: AtomicU64 = AtomicU64::new(0);
static HOOK_RUNNING: AtomicBool = AtomicBool::new(false);
const GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS: u32 = 4;
const GET_MODULE_HANDLE_EX_FLAG_UNCHANGED_REFCOUNT: u32 = 2;

lazy_static::lazy_static! {
    static ref GESTURES: std::sync::Mutex<GestureDetector> = Default::default();
}

pub(crate) fn session_started() {
    if ACTIVE_SESSIONS.fetch_add(1, Ordering::AcqRel) == 0 {
        PAUSED.store(false, Ordering::Release);
        REVISION.store(0, Ordering::Release);
        *GESTURES.lock().unwrap() = GestureDetector::default();
    }
    if HOOK_RUNNING
        .compare_exchange(false, true, Ordering::AcqRel, Ordering::Acquire)
        .is_ok()
    {
        if let Err(err) = std::thread::Builder::new()
            .name("local-control-hook".to_owned())
            .spawn(run_hook)
        {
            hbb_common::log::warn!("Failed to start local control mouse hook: {err}");
            HOOK_RUNNING.store(false, Ordering::Release);
        }
    }
}

pub(crate) fn session_ended() {
    if ACTIVE_SESSIONS.fetch_sub(1, Ordering::AcqRel) == 1 {
        let mut detector = GESTURES.lock().unwrap();
        PAUSED.store(false, Ordering::Release);
        REVISION.store(0, Ordering::Release);
        *detector = GestureDetector::default();
    }
}

pub(crate) fn is_paused() -> bool {
    PAUSED.load(Ordering::Acquire)
}

pub(crate) fn state() -> (u64, bool) {
    (REVISION.load(Ordering::Acquire), is_paused())
}

fn run_hook() {
    unsafe {
        let mut module = ptr::null_mut();
        if GetModuleHandleExA(
            GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS | GET_MODULE_HANDLE_EX_FLAG_UNCHANGED_REFCOUNT,
            mouse_hook as _,
            &mut module,
        ) == 0
        {
            hbb_common::log::warn!(
                "Local control mouse hook module: {}",
                io::Error::last_os_error()
            );
            HOOK_RUNNING.store(false, Ordering::Release);
            return;
        }
        let hook = SetWindowsHookExA(WH_MOUSE_LL, Some(mouse_hook), module, 0);
        if hook.is_null() {
            hbb_common::log::warn!("Local control mouse hook: {}", io::Error::last_os_error());
            HOOK_RUNNING.store(false, Ordering::Release);
            return;
        }
        let mut msg: MSG = std::mem::zeroed();
        loop {
            let result = GetMessageA(&mut msg, ptr::null_mut(), 0, 0);
            if result <= 0 {
                if result < 0 {
                    hbb_common::log::warn!(
                        "Local control mouse hook message loop: {}",
                        io::Error::last_os_error()
                    );
                }
                break;
            }
            TranslateMessage(&msg);
            DispatchMessageA(&msg);
        }
        if UnhookWindowsHookEx(hook) == 0 {
            hbb_common::log::warn!("Unhook local control mouse: {}", io::Error::last_os_error());
        }
        HOOK_RUNNING.store(false, Ordering::Release);
    }
}

unsafe extern "system" fn mouse_hook(code: i32, event: usize, data: isize) -> isize {
    if code >= 0 && event as u32 == WM_MOUSEMOVE && ACTIVE_SESSIONS.load(Ordering::Acquire) > 0 {
        let mouse = &*(data as *const MSLLHOOKSTRUCT);
        if mouse.flags & LLMHF_INJECTED == 0 && mouse.dwExtraInfo != enigo::ENIGO_INPUT_EXTRA_VALUE
        {
            let mut detector = GESTURES.lock().unwrap();
            if ACTIVE_SESSIONS.load(Ordering::Acquire) > 0 {
                let paused = is_paused();
                if detector.push(mouse.pt.x, mouse.pt.y, Instant::now(), paused) {
                    PAUSED.store(!paused, Ordering::Release);
                    REVISION.fetch_add(1, Ordering::AcqRel);
                    *detector = GestureDetector::default();
                }
            }
        }
    }
    CallNextHookEx(ptr::null_mut(), code, event, data)
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum Direction {
    Left,
    Right,
    Up,
    Down,
}

impl Direction {
    fn horizontal(self) -> bool {
        matches!(self, Self::Left | Self::Right)
    }
}

#[derive(Clone, Copy)]
struct Leg {
    direction: Direction,
    start: (i32, i32),
    end: (i32, i32),
    started: Instant,
}

impl Leg {
    fn length(self) -> i32 {
        if self.direction.horizontal() {
            (self.end.0 - self.start.0).abs()
        } else {
            (self.end.1 - self.start.1).abs()
        }
    }
}

#[derive(Default)]
struct GestureDetector {
    previous: Option<(i32, i32)>,
    active: Option<Leg>,
    completed: VecDeque<Leg>,
}

impl GestureDetector {
    fn push(&mut self, x: i32, y: i32, now: Instant, paused: bool) -> bool {
        let point = (x, y);
        let previous = match self.previous {
            Some(previous) => previous,
            None => {
                self.previous = Some(point);
                return false;
            }
        };
        let dx = x - previous.0;
        let dy = y - previous.1;
        if dx.abs() + dy.abs() < 8 {
            return false;
        }
        let direction = if dx.abs() >= dy.abs() * 2 {
            if dx > 0 {
                Direction::Right
            } else {
                Direction::Left
            }
        } else if dy.abs() >= dx.abs() * 2 {
            if dy > 0 {
                Direction::Down
            } else {
                Direction::Up
            }
        } else {
            return false;
        };
        match self.active.as_mut() {
            Some(active) if active.direction == direction => active.end = point,
            Some(_) => {
                if dx.abs() + dy.abs() < 18 {
                    return false;
                }
                if let Some(old) = self.active.take() {
                    if old.length() >= 55 {
                        self.completed.push_back(old);
                    } else {
                        self.completed.clear();
                    }
                }
                self.active = Some(Leg {
                    direction,
                    start: previous,
                    end: point,
                    started: now,
                });
            }
            None => {
                self.active = Some(Leg {
                    direction,
                    start: previous,
                    end: point,
                    started: now,
                })
            }
        }
        self.previous = Some(point);
        while self.completed.len() > 3 {
            self.completed.pop_front();
        }
        let Some(active) = self.active else {
            return false;
        };
        if active.length() < 80 || self.completed.len() != 3 {
            return false;
        }
        let legs: Vec<Leg> = self.completed.iter().copied().chain(Some(active)).collect();
        if !paused {
            let first = legs[0];
            now.duration_since(first.started) <= Duration::from_secs(2)
                && legs
                    .iter()
                    .all(|leg| leg.direction.horizontal() && leg.length() >= 80)
                && legs
                    .windows(2)
                    .all(|pair| pair[0].direction != pair[1].direction)
                && legs
                    .iter()
                    .all(|leg| (leg.end.1 - first.start.1).abs() <= 45)
        } else {
            let first = legs[0];
            now.duration_since(first.started) <= Duration::from_secs(4)
                && legs.iter().all(|leg| leg.length() >= 80)
                && legs
                    .windows(2)
                    .all(|pair| pair[0].direction.horizontal() != pair[1].direction.horizontal())
                && legs[0].direction != legs[2].direction
                && legs[1].direction != legs[3].direction
                && (active.end.0 - first.start.0).abs() <= 45
                && (active.end.1 - first.start.1).abs() <= 45
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn zigzag_pauses_only_after_four_fast_horizontal_legs() {
        let mut detector = GestureDetector::default();
        let start = Instant::now();
        let points = [(0, 0), (110, 0), (0, 0), (110, 0), (0, 0)];
        for (i, (x, y)) in points.iter().copied().enumerate() {
            let recognized =
                detector.push(x, y, start + Duration::from_millis(i as u64 * 300), false);
            assert_eq!(recognized, i == 4);
        }
    }

    #[test]
    fn rectangle_restores_only_when_closed() {
        let mut detector = GestureDetector::default();
        let start = Instant::now();
        let points = [(0, 0), (120, 0), (120, 100), (0, 100), (0, 0)];
        for (i, (x, y)) in points.iter().copied().enumerate() {
            let recognized =
                detector.push(x, y, start + Duration::from_millis(i as u64 * 500), true);
            assert_eq!(recognized, i == 4);
        }
    }

    #[test]
    fn slow_or_open_shapes_do_not_handoff() {
        let mut detector = GestureDetector::default();
        let start = Instant::now();
        for (i, x) in [0, 110, 0, 110, 0].iter().copied().enumerate() {
            assert!(!detector.push(x, 0, start + Duration::from_secs(i as u64), false));
        }
        let mut detector = GestureDetector::default();
        for (i, (x, y)) in [(0, 0), (120, 0), (120, 100), (0, 100), (0, 40)]
            .iter()
            .copied()
            .enumerate()
        {
            assert!(!detector.push(x, y, start + Duration::from_millis(i as u64 * 400), true));
        }
    }

    #[test]
    fn small_corner_jitter_does_not_break_rectangle() {
        let mut detector = GestureDetector::default();
        let start = Instant::now();
        let points = [(0, 0), (120, 0), (115, 1), (120, 100), (0, 100), (0, 0)];
        for (i, (x, y)) in points.iter().copied().enumerate() {
            let recognized =
                detector.push(x, y, start + Duration::from_millis(i as u64 * 350), true);
            assert_eq!(recognized, i == 5);
        }
    }
}
