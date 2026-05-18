package main

import (
	"fmt"
	"os"
	"sync"
	"time"

	uv "github.com/charmbracelet/ultraviolet"
	"github.com/charmbracelet/x/vt"
)

// vtScreen wraps a charmbracelet/x/vt terminal emulator. PTY output is fed
// via Write(); on client reconnect, Snapshot() returns ANSI sequences that
// reconstruct the current screen + scrollback in one shot (no replay).
type vtScreen struct {
	mu   sync.Mutex
	term vt.Terminal
	cols int
	rows int
}

func newVTScreen(cols, rows, scrollback int) *vtScreen {
	if cols < 1 {
		cols = 80
	}
	if rows < 1 {
		rows = 24
	}
	t := vt.NewEmulator(cols, rows)
	t.SetScrollbackSize(scrollback)
	return &vtScreen{term: t, cols: cols, rows: rows}
}

var vtWriteTotal int64

func (v *vtScreen) Write(p []byte) {
	v.mu.Lock()
	n, err := v.term.Write(p)
	vtWriteTotal += int64(n)
	if err != nil {
		logVT("Write error: %v (len=%d written=%d total=%d)", err, len(p), n, vtWriteTotal)
	}
	v.mu.Unlock()
}

func logVT(format string, args ...interface{}) {
	f, err := os.OpenFile("/tmp/belve-persist-vt.log", os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0644)
	if err != nil {
		return
	}
	fmt.Fprintf(f, "%s [vt] "+format+"\n", append([]interface{}{time.Now().Format(time.RFC3339)}, args...)...)
	f.Close()
}

func (v *vtScreen) Resize(cols, rows int) {
	v.mu.Lock()
	if cols < 1 {
		cols = 1
	}
	if rows < 1 {
		rows = 1
	}
	v.term.Resize(cols, rows)
	v.cols = cols
	v.rows = rows
	v.mu.Unlock()
}

func (v *vtScreen) Reset() {
	v.mu.Lock()
	v.term.ClearScrollback()
	// Recreate emulator to fully reset state
	t := vt.NewEmulator(v.cols, v.rows)
	t.SetScrollbackSize(1000)
	v.term = t
	v.mu.Unlock()
}

// Snapshot serializes the current screen state (scrollback + visible screen)
// as ANSI escape sequences. The output can be written to xterm.js to restore
// the terminal to the exact current state without replay.
func (v *vtScreen) Snapshot() []byte {
	v.mu.Lock()
	defer v.mu.Unlock()

	cols := v.cols
	rows := v.rows
	sb := v.term.Scrollback()
	sbLen := 0
	if sb != nil {
		sbLen = sb.Len()
	}
	isAlt := v.term.IsAltScreen()
	curPos := v.term.CursorPosition()

	buf := make([]byte, 0, (sbLen+rows)*100)

	logVT("Snapshot: cols=%d rows=%d sbLen=%d isAlt=%v cursor=(%d,%d) totalWritten=%d",
		cols, rows, sbLen, isAlt, curPos.X, curPos.Y, vtWriteTotal)

	// 1. Hide cursor + clear everything
	buf = append(buf, "\033[?25l\033[H\033[2J\033[3J"...)

	// 2. Alt buffer if needed
	if isAlt {
		buf = append(buf, "\033[?1049h"...)
	}

	// 3. Scrollback lines (oldest first) — flow naturally into xterm.js scrollback
	if !isAlt && sbLen > 0 {
		for i := 0; i < sbLen; i++ {
			line := sb.Line(i)
			buf = appendStyledLine(buf, line, cols)
			buf = append(buf, "\r\n"...)
		}
	}

	// 4. Visible screen rows — emit sequentially, \r\n between rows.
	//    After scrollback lines pushed viewport, these land on the visible screen.
	for y := 0; y < rows; y++ {
		var line uv.Line
		for x := 0; x < cols; x++ {
			cell := v.term.CellAt(x, y)
			if cell == nil {
				line = append(line, uv.EmptyCell)
			} else {
				line = append(line, *cell)
			}
		}
		buf = appendStyledLine(buf, line, cols)
		if y < rows-1 {
			buf = append(buf, "\r\n"...)
		}
	}

	// 5. Restore cursor position (1-based) + show cursor
	buf = append(buf, fmt.Sprintf("\033[%d;%dH\033[?25h", curPos.Y+1, curPos.X+1)...)

	logVT("Snapshot result: %d bytes", len(buf))

	return buf
}

// appendStyledLine appends a line's cells with SGR attributes to buf.
// Trailing empty cells are trimmed to reduce output size.
func appendStyledLine(buf []byte, line uv.Line, maxCols int) []byte {
	if len(line) == 0 {
		return buf
	}

	// Find last non-empty cell
	lastNonEmpty := -1
	for i := len(line) - 1; i >= 0; i-- {
		c := &line[i]
		if !c.IsZero() && c.Content != " " {
			lastNonEmpty = i
			break
		}
		// Also keep styled spaces (colored background etc)
		if !c.Style.IsZero() {
			lastNonEmpty = i
			break
		}
	}
	if lastNonEmpty < 0 {
		return buf
	}

	var prevStyle uv.Style
	styleActive := false

	for i := 0; i <= lastNonEmpty && i < maxCols; i++ {
		cell := &line[i]
		content := cell.Content
		if content == "" {
			content = " "
		}
		// Width 0 = continuation cell of a wide char, skip
		if cell.Width == 0 && i > 0 {
			continue
		}

		// Emit SGR if style changed
		if !cell.Style.Equal(&prevStyle) {
			if cell.Style.IsZero() {
				buf = append(buf, "\033[0m"...)
			} else {
				buf = append(buf, cell.Style.String()...)
			}
			prevStyle = cell.Style
			styleActive = !cell.Style.IsZero()
		}

		buf = append(buf, content...)
	}

	// Reset style at end of line if active
	if styleActive {
		buf = append(buf, "\033[0m"...)
	}

	return buf
}
