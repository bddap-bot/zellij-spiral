//! zellij-spiral — the focused pane keeps the big slot; every other pane
//! collapses into a stack ordered by how recently it was focused.
//!
//! zellij has no notion of "most recently used" — it only tracks panes in
//! creation order. So the plugin keeps that ordering itself: it watches focus
//! changes and, on each one, promotes the newly-focused pane and re-stacks the
//! remainder. `stack_panes` is the native primitive that makes the non-focused
//! panes collapse to title-bars while the focused one stays expanded.

use std::collections::BTreeMap;
use zellij_tile::prelude::*;

#[derive(Default)]
struct State {
    /// Terminal pane ids, most-recently-focused first. Plugin-owned because
    /// zellij won't track recency for us.
    mru: Vec<u32>,
    /// The last terminal pane we saw focused. We act only on a *change* — both
    /// to avoid needless restacking and so we ignore the `PaneUpdate` our own
    /// restack emits (focus stays put through a restack, so it won't re-fire).
    last_focused: Option<u32>,
}

register_plugin!(State);

impl ZellijPlugin for State {
    fn load(&mut self, _configuration: BTreeMap<String, String>) {
        // ReadApplicationState → receive PaneUpdate; ChangeApplicationState →
        // issue stack_panes. Both are requested up front; zellij prompts the
        // user to grant them once.
        request_permission(&[
            PermissionType::ReadApplicationState,
            PermissionType::ChangeApplicationState,
        ]);
        subscribe(&[EventType::PaneUpdate]);
    }

    fn update(&mut self, event: Event) -> bool {
        if let Event::PaneUpdate(manifest) = event {
            self.on_pane_update(manifest);
        }
        false // this plugin draws nothing
    }

    fn render(&mut self, _rows: usize, _cols: usize) {}
}

impl State {
    fn on_pane_update(&mut self, manifest: PaneManifest) {
        // Gather the live terminal panes (ignore plugin panes — including our
        // own) and which one is focused.
        let mut focused: Option<u32> = None;
        let mut live: Vec<u32> = Vec::new();
        for panes in manifest.panes.values() {
            for pane in panes {
                if pane.is_plugin {
                    continue;
                }
                live.push(pane.id);
                if pane.is_focused {
                    focused = Some(pane.id);
                }
            }
        }

        // Reconcile the MRU with reality: forget closed panes, append new ones
        // at the least-recent end until they're focused.
        self.mru.retain(|id| live.contains(id));
        for id in &live {
            if !self.mru.contains(id) {
                self.mru.push(*id);
            }
        }

        let Some(focused) = focused else {
            return;
        };
        if self.last_focused == Some(focused) {
            return; // no focus change → nothing to do (and no restack echo loop)
        }
        self.last_focused = Some(focused);

        // Promote the focused pane to master; keep the rest in recency order.
        self.mru.retain(|&id| id != focused);
        self.mru.insert(0, focused);

        // Collapse everyone but the master into a stack, in MRU order.
        if self.mru.len() >= 2 {
            let stack: Vec<PaneId> = self.mru[1..].iter().map(|&id| PaneId::Terminal(id)).collect();
            stack_panes(stack);
        }
    }
}
