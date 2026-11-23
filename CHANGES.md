# Iteration 3

Changes since iteration 2.

- Accessibility (optional permission):
  - snow falls as soon as the system reports that a window was minimized, instead of when the window disappears;
  - a drift forms on the Dock itself when the Dock is at the bottom of the screen;
  - new menu item shows the permission state and opens the settings pane.
- Window physics:
  - snow slides against the motion while a window is dragged and settles flatter;
  - fast drags (from about 700 pt/s) and jerks knock snow off in clumps that keep the window's momentum.
- Cursor: the plain cursor now always pushes snow into a heap ahead of it; fast strokes throw part of it off. The mitten is wider and sweeps most of the snow away.
- Nothing vanishes mid-air: clumps that hit a full drift keep falling, snow that reaches a window edge drops off the corner, and swept snow falls as clumps. All of it lands on lower windows, the Dock or the ground.
- The window list is polled more often so drifts follow dragged windows more closely.
- README gains the Accessibility setup instructions.
