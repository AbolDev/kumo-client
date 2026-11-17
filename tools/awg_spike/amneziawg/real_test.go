package amneziawg

import (
	"bufio"
	"fmt"
	"net"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

// TestRealServer talks to the amneziawg-go program (a process of its own, with a real TUN device of the kernel) as a server
// does. It needs root and the program (AWG_REAL_BIN), so that it is skipped otherwise.
func TestRealServer(t *testing.T) {
	bin := os.Getenv("AWG_REAL_BIN")
	if bin == "" || os.Geteuid() != 0 {
		t.Skip("AWG_REAL_BIN and root are needed")
	}
	const iface = "awgtest0"
	cmd := exec.Command(bin, "-f", iface)
	cmd.Stdout, cmd.Stderr = os.Stderr, os.Stderr
	if err := cmd.Start(); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		exec.Command("ip", "link", "del", iface).Run()
		cmd.Process.Kill()
		cmd.Wait()
	})
	// its control socket
	var sock string
	for i := 0; i < 50 && sock == ""; i++ {
		for _, dir := range []string{"/var/run/amneziawg", "/var/run/wireguard", "/run/amneziawg", "/run/wireguard"} {
			if m, _ := filepath.Glob(filepath.Join(dir, iface+".sock")); len(m) > 0 {
				sock = m[0]
			}
		}
		time.Sleep(100 * time.Millisecond)
	}
	if sock == "" {
		t.Fatal("the program made no control socket")
	}
	serverPrivate, serverPublic := newKey(t)
	clientPrivate, clientPublic := newKey(t)
	const port = 51871
	uapi := fmt.Sprintf("set=1\nprivate_key=%x\nlisten_port=%d%s\npublic_key=%x\nallowed_ip=10.9.0.2/32\n\n", serverPrivate, port,
		"\njc=5\njmin=30\njmax=80\ns1=17\ns2=29\ns3=19\ns4=11\nh1=1000000-1000999\nh2=2000000-2000999\nh3=3000000-3000999\nh4=4000000-4000999"+
			"\ni1=<b 0xc0ffee><t><r 16>", clientPublic)
	c, err := net.Dial("unix", sock)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := c.Write([]byte(uapi)); err != nil {
		t.Fatal(err)
	}
	reply, _ := bufio.NewReader(c).ReadString('\n')
	c.Close()
	if strings.TrimSpace(reply) != "errno=0" {
		t.Fatalf("the program refused the configuration: %q", reply)
	}
	for _, args := range [][]string{
		{"addr", "add", "10.9.0.1/24", "dev", iface},
		{"link", "set", "dev", iface, "up"},
	} {
		if out, err := exec.Command("ip", args...).CombinedOutput(); err != nil {
			t.Fatalf("ip %v: %v %s", args, err, out)
		}
	}
	// an echo on the server's side of the tunnel, in the kernel
	listener, err := net.Listen("tcp", "10.9.0.1:8080")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { listener.Close() })
	go func() {
		for {
			conn, err := listener.Accept()
			if err != nil {
				return
			}
			go func() {
				defer conn.Close()
				buf := make([]byte, 4096)
				for {
					n, err := conn.Read(buf)
					if n > 0 {
						conn.Write(buf[:n])
					}
					if err != nil {
						return
					}
				}
			}()
		}
	}()
	awg := AWGOptions{
		Jc: 5, Jmin: 30, Jmax: 80, S1: 17, S2: 29, S3: 19, S4: 11,
		H1: "1000000-1000999", H2: "2000000-2000999", H3: "3000000-3000999", H4: "4000000-4000999",
		I1: "<b 0xc0ffee><t><r 16>",
	}
	opts := singlePeer(port, serverPublic, "10.9.0.0/24", awg, "10.9.0.2/32")
	opts.PrivateKey = b64(clientPrivate)
	if err := echoTo(startClient(t, opts), "10.9.0.1", 15*time.Second); err != nil {
		t.Fatal(err)
	}
}