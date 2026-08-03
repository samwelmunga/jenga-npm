# E06_S02_T02 Plan — Epic / Story / Task Cards

Create `EpicCard`, `StoryCard`, `TaskCard`, and `StatusBadge` components under `src/components/board/`. Each card renders its title, id, and a colour-coded `StatusBadge`, then recursively renders its children (stories → tasks). Status colours: pending=grey, running=blue, in-progress=orange, passed=green, failed=red.
