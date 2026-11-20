// The text shown when Kumo moves its proxy port out of a range Windows keeps for itself.

const extraPortEn = <String, String>{
  'proxyPortBusy': 'Another program is using port {old}, so Kumo could not listen on it. The proxy port is now {port}.',
  'proxyPortMoved': 'Windows keeps port {old} for itself (Hyper-V, WSL or Docker), so Kumo could not listen on it. The proxy port is now {port}.',
};

const extraPortFa = <String, String>{
  'proxyPortBusy': 'برنامه‌ی دیگری از پورت {old} استفاده می‌کند و Kumo نمی‌توانست روی آن گوش بدهد. پورت پروکسی حالا {port} است.',
  'proxyPortMoved': 'ویندوز پورت {old} را برای خودش نگه داشته است (Hyper-V، WSL یا Docker) و Kumo نمی‌توانست روی آن گوش بدهد. پورت پروکسی حالا {port} است.',
};

const extraPortRu = <String, String>{
  'proxyPortBusy': 'Другая программа использует порт {old}, поэтому Kumo не смогла его слушать. Порт прокси теперь {port}.',
  'proxyPortMoved': 'Windows зарезервировала порт {old} для себя (Hyper-V, WSL или Docker), и Kumo не могла его слушать. Порт прокси теперь {port}.',
};

const extraPortVi = <String, String>{
  'proxyPortBusy': 'Một chương trình khác đang dùng cổng {old} nên Kumo không thể lắng nghe trên đó. Cổng proxy hiện là {port}.',
  'proxyPortMoved': 'Windows giữ cổng {old} cho riêng mình (Hyper-V, WSL hoặc Docker) nên Kumo không thể lắng nghe trên đó. Cổng proxy hiện là {port}.',
};

const extraPortZh = <String, String>{
  'proxyPortBusy': '端口 {old} 正被其他程序占用，Kumo 无法监听。代理端口已改为 {port}。',
  'proxyPortMoved': 'Windows 保留了端口 {old}（用于 Hyper-V、WSL 或 Docker），Kumo 无法监听该端口。代理端口已改为 {port}。',
};

const extraPortAr = <String, String>{
  'proxyPortBusy': 'برنامج آخر يستخدم المنفذ {old} لذلك لم يستطع Kumo الاستماع عليه. منفذ الوكيل الآن {port}.',
  'proxyPortMoved': 'يحتفظ Windows بالمنفذ {old} لنفسه (Hyper-V أو WSL أو Docker) لذلك لم يستطع Kumo الاستماع عليه. منفذ الوكيل الآن {port}.',
};