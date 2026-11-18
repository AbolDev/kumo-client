// Added to the command line client of SlipNet when kumo-slip is built (see tools/build_slip.sh). Kumo starts every program that
// carries a server for it the way it starts Xray: `kumo-slip run -c config.json`, with a local SOCKS5 port the core sends to. This
// file reads that configuration before the client's own main does:
//
//	{"slipnet": {"link": "slipnet://...", "port": 1080, "dns": "1.1.1.1", "args": ["--direct"]}}   DNSTT, NoizDNS, VayDNS, SSH ...
//	{"soar": {"resolvers": "1.1.1.1,8.8.8.8", "zone": "t.example.com", "key": "base64", "listen": "127.0.0.1:1080",
//	          "discovery": true, "country": "IR"}}                                                  Soar
//
// A `slipnet` one is turned into the arguments the client takes (so the client does what it does for its own users); a `soar` one
// is run here, with the Soar client of SlipNet's Android app.
package main

import (
	"encoding/json"
	"fmt"
	"os"
	"os/signal"
	"strconv"
	"syscall"

	soar "soar-mobile/soar"
)

type kumoConfig struct {
	Slipnet *struct {
		Link string   `json:"link"`
		Port int      `json:"port"`
		DNS  string   `json:"dns"`
		Args []string `json:"args"`
	} `json:"slipnet"`
	Soar *struct {
		Resolvers  string `json:"resolvers"`
		Zone       string `json:"zone"`
		Key        string `json:"key"`
		Listen     string `json:"listen"`
		Discovery  bool   `json:"discovery"`
		Country    string `json:"country"`
		Candidates string `json:"candidates"`
		TCPMode    string `json:"tcp_mode"`
		SafeQName  int    `json:"safe_qname"`
		Verbose    bool   `json:"verbose"`
	} `json:"soar"`
}

func init() {
	if len(os.Args) != 4 || os.Args[1] != "run" || os.Args[2] != "-c" {
		return
	}
	data, err := os.ReadFile(os.Args[3])
	if err != nil {
		fmt.Fprintln(os.Stderr, "kumo-slip:", err)
		os.Exit(2)
	}
	var c kumoConfig
	if err := json.Unmarshal(data, &c); err != nil {
		fmt.Fprintln(os.Stderr, "kumo-slip: the configuration is not valid:", err)
		os.Exit(2)
	}
	switch {
	case c.Soar != nil:
		runSoar(c)
	case c.Slipnet != nil && c.Slipnet.Link != "":
		args := []string{os.Args[0]}
		if c.Slipnet.Port > 0 {
			args = append(args, "--port", strconv.Itoa(c.Slipnet.Port))
		}
		if c.Slipnet.DNS != "" {
			args = append(args, "--dns", c.Slipnet.DNS)
		}
		args = append(args, c.Slipnet.Args...)
		os.Args = append(args, c.Slipnet.Link)
	default:
		fmt.Fprintln(os.Stderr, "kumo-slip: the configuration has neither a slipnet nor a soar server")
		os.Exit(2)
	}
}

func runSoar(c kumoConfig) {
	s := c.Soar
	client, err := soar.NewClient(s.Resolvers, s.Zone, s.Key, s.Listen)
	if err != nil {
		fmt.Fprintln(os.Stderr, "kumo-slip: soar:", err)
		os.Exit(2)
	}
	client.SetDiscovery(s.Discovery, s.Country)
	if s.Candidates != "" {
		client.SetDiscoveryCandidates(s.Candidates)
	}
	if s.TCPMode != "" {
		client.SetTCPMode(s.TCPMode)
	}
	if s.SafeQName > 0 {
		client.SetSafeQName(s.SafeQName)
	}
	client.SetVerbose(s.Verbose)
	if err := client.Start(); err != nil {
		fmt.Fprintln(os.Stderr, "kumo-slip: soar:", err)
		os.Exit(1)
	}
	stop := make(chan os.Signal, 1)
	signal.Notify(stop, os.Interrupt, syscall.SIGTERM)
	<-stop
	client.Stop()
	os.Exit(0)
}
