package libbox

import (
	"os"

	"github.com/sagernet/sing-box/common/srs"
	C "github.com/sagernet/sing-box/constant"
	"github.com/sagernet/sing-box/option"
	"github.com/sagernet/sing/common/json"
)

// CompileRuleSet is Kumo's addition to libbox (copied in by tools/build_libbox.ps1 and the workflow).
//
// It writes the rule-set at sourcePath (sing-box's source format, JSON) to outputPath in the binary
// format, as `sing-box rule-set compile` does. A list of a million domains in JSON has to be read
// and turned into a lookup structure every time the core starts; the binary file holds that
// structure already, so the core starts in a fraction of the time and with less memory. The file is
// written next to outputPath first and moved into place when complete.
func CompileRuleSet(sourcePath string, outputPath string) error {
	content, err := os.ReadFile(sourcePath)
	if err != nil {
		return err
	}
	plain, err := json.UnmarshalExtended[option.PlainRuleSetCompat](content)
	if err != nil {
		return err
	}
	content = nil
	// Kumo's lists hold domains only: version 2 (the compact domain structure) is all they need, and
	// every core since 1.10 reads it.
	version := plain.Version
	if version > C.RuleSetVersion2 {
		version = C.RuleSetVersion2
	}
	tmp := outputPath + ".tmp"
	file, err := os.Create(tmp)
	if err != nil {
		return err
	}
	err = srs.Write(file, plain.Options, version)
	closeErr := file.Close()
	if err == nil {
		err = closeErr
	}
	if err != nil {
		os.Remove(tmp)
		return err
	}
	return os.Rename(tmp, outputPath)
}
