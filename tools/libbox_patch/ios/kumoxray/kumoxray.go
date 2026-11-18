// Package kumoxray is Xray-core as a library, for the tunnel extension on iOS. A program of its own is not possible there (an app
// cannot start another program), and a second Go framework in the same process does not work (two Go runtimes): so this package is
// built into the same framework as libbox (see .github/workflows/ios-test.yml, the job `libbox`), and the extension starts Xray in itself
// with the configuration the app gives, a local SOCKS inbound that sing-box sends the servers only Xray can carry to.
package kumoxray

import (
	"strings"
	"sync"

	"github.com/xtls/xray-core/core"
	"github.com/xtls/xray-core/infra/conf/serial"
	_ "github.com/xtls/xray-core/main/distro/all"
)

var (
	lock     sync.Mutex
	instance *core.Instance
)

// Start runs Xray with [config] (the JSON of Xray). A running one is stopped first.
func Start(config string) error {
	lock.Lock()
	defer lock.Unlock()
	if instance != nil {
		_ = instance.Close()
		instance = nil
	}
	parsed, err := serial.LoadJSONConfig(strings.NewReader(config))
	if err != nil {
		return err
	}
	next, err := core.New(parsed)
	if err != nil {
		return err
	}
	if err := next.Start(); err != nil {
		_ = next.Close()
		return err
	}
	instance = next
	return nil
}

// Stop ends the running Xray, if any.
func Stop() error {
	lock.Lock()
	defer lock.Unlock()
	if instance == nil {
		return nil
	}
	err := instance.Close()
	instance = nil
	return err
}

// Running says whether an Xray is running.
func Running() bool {
	lock.Lock()
	defer lock.Unlock()
	return instance != nil
}

// Version is the version of the Xray in the framework.
func Version() string {
	return core.Version()
}

var _ = errors.New