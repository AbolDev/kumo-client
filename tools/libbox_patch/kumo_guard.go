package libbox

import (
	"fmt"
	"os"
	"runtime/debug"

	E "github.com/sagernet/sing/common/exceptions"
)

// kumoGuard runs work for one of Kumo's additions (MeasureDelay, MeasureSpeed, Inspect) and puts its error in err.
//
// The work is done on a goroutine of its own and not on the one the call from Java arrived on: on Android the stack
// of that one is not what the Go runtime takes it for (golang/go#68760, the reason libbox starts its service this
// way too), and a throw-away core is started on it for every test. A panic in the work ends the test with an error
// instead of ending the app; its trace is written to the error output (the file the app keeps as stderr.log), so
// that it can be read afterwards. A panic on a goroutine that the core started itself is not caught by this.
func kumoGuard(err *error, work func() error) {
	done := make(chan struct{})
	go func() {
		defer close(done)
		defer func() {
			if r := recover(); r != nil {
				fmt.Fprintf(os.Stderr, "kumo: panic in a test core: %v\n\ngoroutine 0 [recovered]:\n%s\n", r, debug.Stack())
				*err = E.New("panic: ", fmt.Sprint(r))
			}
		}()
		*err = work()
	}()
	<-done
}
