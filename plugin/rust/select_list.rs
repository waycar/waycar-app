//! Pure state for the popup's address checklist (select-list.js). The popup
//! is a thin render loop over these transitions, so selection behavior stays
//! testable without a terminal.

use crate::addresses::Candidate;

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Item {
    pub candidate: Candidate,
    pub checked: bool,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Selection {
    pub items: Vec<Item>,
    pub cursor: usize,
}

impl Selection {
    /// Pre-checked candidates start checked; the cursor is on the first row.
    /// The popup never builds one from no candidates.
    pub fn new(candidates: Vec<Candidate>) -> Self {
        let items = candidates
            .into_iter()
            .map(|candidate| Item {
                checked: candidate.pre_checked,
                candidate,
            })
            .collect();
        Self { items, cursor: 0 }
    }

    /// Move the cursor by `delta` rows, stopping at both ends.
    pub fn move_cursor(&mut self, delta: isize) {
        let last = self.items.len().saturating_sub(1);
        self.cursor = self.cursor.saturating_add_signed(delta).min(last);
    }

    pub fn toggle_current(&mut self) {
        if let Some(item) = self.items.get_mut(self.cursor) {
            item.checked = !item.checked;
        }
    }

    /// Check everything, or uncheck everything when it all is checked.
    pub fn toggle_all(&mut self) {
        let checked = !self.items.iter().all(|item| item.checked);
        for item in &mut self.items {
            item.checked = checked;
        }
    }

    /// The checked addresses in candidate order.
    pub fn selected_addresses(&self) -> Vec<String> {
        self.items
            .iter()
            .filter(|item| item.checked)
            .map(|item| item.candidate.address.clone())
            .collect()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::addresses::Family;

    fn candidate(address: &str, interface_name: &str, pre_checked: bool) -> Candidate {
        Candidate {
            address: address.to_string(),
            family: Family::V4,
            interface_name: interface_name.to_string(),
            pre_checked,
        }
    }

    fn candidates() -> Vec<Candidate> {
        vec![
            candidate("192.168.1.42", "en0", true),
            candidate("100.101.102.103", "utun3", true),
            candidate("203.0.113.9", "en1", false),
        ]
    }

    #[test]
    fn starts_with_pre_checked_candidates_selected_and_cursor_on_the_first_row() {
        let state = Selection::new(candidates());
        assert_eq!(state.cursor, 0);
        assert_eq!(
            state.selected_addresses(),
            ["192.168.1.42", "100.101.102.103"]
        );
    }

    #[test]
    fn cursor_movement_clamps_at_both_ends() {
        let mut state = Selection::new(candidates());
        state.move_cursor(-1);
        assert_eq!(state.cursor, 0);
        for _ in 0..3 {
            state.move_cursor(1);
        }
        assert_eq!(state.cursor, 2);
    }

    #[test]
    fn toggling_flips_only_the_row_under_the_cursor() {
        let mut state = Selection::new(candidates());
        state.move_cursor(1);
        state.toggle_current();
        assert_eq!(state.selected_addresses(), ["192.168.1.42"]);
        state.toggle_current();
        assert_eq!(
            state.selected_addresses(),
            ["192.168.1.42", "100.101.102.103"]
        );
    }

    #[test]
    fn toggle_all_checks_everything_then_unchecks_everything() {
        let mut state = Selection::new(candidates());
        state.toggle_all();
        assert_eq!(
            state.selected_addresses(),
            ["192.168.1.42", "100.101.102.103", "203.0.113.9"]
        );
        state.toggle_all();
        assert!(state.selected_addresses().is_empty());
    }

    #[test]
    fn selected_addresses_keep_candidate_order_regardless_of_toggle_order() {
        let mut state = Selection::new(candidates());
        state.move_cursor(1);
        state.move_cursor(1);
        state.toggle_current();
        assert_eq!(
            state.selected_addresses(),
            ["192.168.1.42", "100.101.102.103", "203.0.113.9"]
        );
    }
}
