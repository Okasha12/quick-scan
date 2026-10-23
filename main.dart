import 'dart:io';
import 'package:cunning_document_scanner/cunning_document_scanner.dart';
import 'package:flutter/material.dart';
import 'package:google_mobile_ads/google_mobile_ads.dart';
import 'package:path_provider/path_provider.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:share_plus/share_plus.dart';

// ---- Google TEST ad unit IDs. Replace with your own AdMob IDs ONLY at release. ----
const bannerId = 'ca-app-pub-3940256099942544/6300978111';
const interId = 'ca-app-pub-3940256099942544/1033173712';
const rewardId = 'ca-app-pub-3940256099942544/5224354917';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  Ads.init();
  runApp(const QuickScanApp());
}

class QuickScanApp extends StatelessWidget {
  const QuickScanApp({super.key});
  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'QuickScan',
        debugShowCheckedModeBanner: false,
        theme: ThemeData(colorSchemeSeed: const Color(0xFF1E6FFF), useMaterial3: true),
        home: const Home(),
      );
}

// ===================== ADS =====================
class Ads {
  static InterstitialAd? _i;
  static RewardedAd? _r;
  static int _actions = 0;
  static DateTime _last = DateTime.now();

  static void init() {
    MobileAds.instance.initialize();
    _loadI();
    _loadR();
  }

  static void _loadI() => InterstitialAd.load(
        adUnitId: interId,
        request: const AdRequest(),
        adLoadCallback: InterstitialAdLoadCallback(onAdLoaded: (a) => _i = a, onAdFailedToLoad: (_) => _i = null),
      );

  static void _loadR() => RewardedAd.load(
        adUnitId: rewardId,
        request: const AdRequest(),
        rewardedAdLoadCallback: RewardedAdLoadCallback(onAdLoaded: (a) => _r = a, onAdFailedToLoad: (_) => _r = null),
      );

  /// Call after a completed task (e.g. a scan was saved). Shows 1 ad per 3 actions, min 2 min gap.
  static void afterAction() {
    _actions++;
    final ad = _i;
    if (_actions % 3 != 0 || ad == null || DateTime.now().difference(_last).inMinutes < 2) return;
    ad.fullScreenContentCallback = FullScreenContentCallback(
      onAdDismissedFullScreenContent: (a) { a.dispose(); _i = null; _loadI(); },
      onAdFailedToShowFullScreenContent: (a, e) { a.dispose(); _i = null; _loadI(); },
    );
    ad.show();
    _last = DateTime.now();
  }

  /// User-initiated rewarded ad. Returns false if no ad is ready.
  static bool showRewarded(VoidCallback onReward) {
    final ad = _r;
    if (ad == null) { _loadR(); return false; }
    ad.fullScreenContentCallback = FullScreenContentCallback(
      onAdDismissedFullScreenContent: (a) { a.dispose(); _r = null; _loadR(); },
      onAdFailedToShowFullScreenContent: (a, e) { a.dispose(); _r = null; _loadR(); },
    );
    ad.show(onUserEarnedReward: (_, __) => onReward());
    return true;
  }
}

class BannerBox extends StatefulWidget {
  const BannerBox({super.key});
  @override
  State<BannerBox> createState() => _BannerBoxState();
}

class _BannerBoxState extends State<BannerBox> {
  BannerAd? _ad;
  bool _ok = false;
  @override
  void initState() {
    super.initState();
    _ad = BannerAd(
      size: AdSize.banner,
      adUnitId: bannerId,
      request: const AdRequest(),
      listener: BannerAdListener(
        onAdLoaded: (_) => setState(() => _ok = true),
        onAdFailedToLoad: (ad, _) => ad.dispose(),
      ),
    )..load();
  }

  @override
  void dispose() { _ad?.dispose(); super.dispose(); }

  @override
  Widget build(BuildContext context) => _ok
      ? SafeArea(top: false, child: SizedBox(width: 320, height: 50, child: AdWidget(ad: _ad!)))
      : const SizedBox.shrink();
}

// ===================== STORAGE =====================
Future<Directory> scansDir() async {
  final d = Directory('${(await getApplicationDocumentsDirectory()).path}/scans');
  if (!await d.exists()) await d.create(recursive: true);
  return d;
}

/// Folder name = "<millis>_<name>", pages inside as page_01.jpg, page_02.jpg ...
class Doc {
  final Directory dir;
  Doc(this.dir);
  String get _base => dir.path.split('/').last;
  String get name => _base.split('_').skip(1).join('_');
  DateTime get date => DateTime.fromMillisecondsSinceEpoch(int.tryParse(_base.split('_').first) ?? 0);
  List<File> get pages => dir.listSync().whereType<File>().toList()..sort((a, b) => a.path.compareTo(b.path));
}

Future<File> makePdf(Doc d, {required bool watermark}) async {
  final pdf = pw.Document();
  for (final f in d.pages) {
    final img = pw.MemoryImage(await f.readAsBytes());
    pdf.addPage(pw.Page(
      pageFormat: PdfPageFormat.a4,
      margin: pw.EdgeInsets.zero,
      build: (_) => pw.Stack(children: [
        pw.Center(child: pw.Image(img, fit: pw.BoxFit.contain)),
        if (watermark)
          pw.Positioned(
            bottom: 8,
            right: 12,
            child: pw.Text('Scanned with QuickScan', style: const pw.TextStyle(fontSize: 9, color: PdfColors.grey)),
          ),
      ]),
    ));
  }
  final out = File('${(await getTemporaryDirectory()).path}/${d.name}.pdf');
  await out.writeAsBytes(await pdf.save());
  return out;
}

void snack(BuildContext c, String m) => ScaffoldMessenger.of(c).showSnackBar(SnackBar(content: Text(m)));

// ===================== SCREEN 1: HOME =====================
class Home extends StatefulWidget {
  const Home({super.key});
  @override
  State<Home> createState() => _HomeState();
}

class _HomeState extends State<Home> {
  List<Doc> docs = [];
  bool loading = true;

  @override
  void initState() { super.initState(); load(); }

  Future<void> load() async {
    final d = await scansDir();
    final l = d.listSync().whereType<Directory>().map((e) => Doc(e)).toList()
      ..sort((a, b) => b.date.compareTo(a.date));
    if (mounted) setState(() { docs = l; loading = false; });
  }

  Future<void> scan() async {
    try {
      final p = await CunningDocumentScanner.getPictures(noOfPages: 20, isGalleryImportAllowed: true);
      if (p == null || p.isEmpty || !mounted) return;
      final saved = await Navigator.push<bool>(context, MaterialPageRoute(builder: (_) => AddScreen(paths: p)));
      if (saved == true) { await load(); Ads.afterAction(); }
    } catch (e) {
      if (mounted) snack(context, 'Could not open scanner. Check camera permission.');
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(
          title: const Text('QuickScan'),
          actions: [
            IconButton(
              icon: const Icon(Icons.settings_outlined),
              onPressed: () async {
                await Navigator.push(context, MaterialPageRoute(builder: (_) => const SettingsScreen()));
                load();
              },
            ),
          ],
        ),
        body: loading
            ? const Center(child: CircularProgressIndicator())
            : docs.isEmpty
                ? const Center(
                    child: Padding(
                      padding: EdgeInsets.all(32),
                      child: Text('No scans yet.\nTap Scan to capture your first document.',
                          textAlign: TextAlign.center, style: TextStyle(fontSize: 16)),
                    ),
                  )
                : ListView.builder(
                    itemCount: docs.length,
                    itemBuilder: (_, i) {
                      final d = docs[i];
                      final pg = d.pages;
                      return ListTile(
                        leading: pg.isEmpty
                            ? const Icon(Icons.description)
                            : ClipRRect(
                                borderRadius: BorderRadius.circular(6),
                                child: Image.file(pg.first, width: 48, height: 48, fit: BoxFit.cover, cacheWidth: 120)),
                        title: Text(d.name, maxLines: 1, overflow: TextOverflow.ellipsis),
                        subtitle: Text('${pg.length} page${pg.length == 1 ? '' : 's'} • ${d.date.toString().substring(0, 16)}'),
                        onTap: () async {
                          await Navigator.push(context, MaterialPageRoute(builder: (_) => DetailScreen(doc: d)));
                          load();
                        },
                      );
                    },
                  ),
        floatingActionButton: FloatingActionButton.extended(
          onPressed: scan,
          icon: const Icon(Icons.document_scanner),
          label: const Text('Scan'),
        ),
        bottomNavigationBar: const BannerBox(),
      );
}

// ===================== SCREEN 2: ADD (name + save) =====================
class AddScreen extends StatefulWidget {
  final List<String> paths;
  const AddScreen({super.key, required this.paths});
  @override
  State<AddScreen> createState() => _AddScreenState();
}

class _AddScreenState extends State<AddScreen> {
  late final TextEditingController name =
      TextEditingController(text: 'Scan ${DateTime.now().toString().substring(0, 10)}');
  bool saving = false;

  Future<void> save() async {
    setState(() => saving = true);
    final clean = name.text.replaceAll(RegExp(r'[^A-Za-z0-9 \-]'), '').trim();
    final root = await scansDir();
    final dir = Directory('${root.path}/${DateTime.now().millisecondsSinceEpoch}_${clean.isEmpty ? 'Scan' : clean}');
    await dir.create();
    for (var i = 0; i < widget.paths.length; i++) {
      await File(widget.paths[i]).copy('${dir.path}/page_${(i + 1).toString().padLeft(2, '0')}.jpg');
    }
    if (mounted) Navigator.pop(context, true);
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: Text('${widget.paths.length} page(s) scanned')),
        body: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(children: [
            TextField(controller: name, decoration: const InputDecoration(labelText: 'Document name', border: OutlineInputBorder())),
            const SizedBox(height: 16),
            Expanded(
              child: GridView.count(
                crossAxisCount: 3,
                mainAxisSpacing: 8,
                crossAxisSpacing: 8,
                childAspectRatio: 0.75,
                children: [for (final p in widget.paths) Image.file(File(p), fit: BoxFit.cover, cacheWidth: 400)],
              ),
            ),
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed: saving ? null : save,
                icon: const Icon(Icons.save),
                label: Text(saving ? 'Saving...' : 'Save'),
              ),
            ),
          ]),
        ),
        bottomNavigationBar: const BannerBox(),
      );
}

// ===================== SCREEN 3: DETAIL (view, share PDF, delete) =====================
class DetailScreen extends StatelessWidget {
  final Doc doc;
  const DetailScreen({super.key, required this.doc});

  Future<void> _share(BuildContext c, {required bool watermark}) async {
    final f = await makePdf(doc, watermark: watermark);
    await Share.shareXFiles([XFile(f.path)], text: doc.name);
  }

  @override
  Widget build(BuildContext context) {
    final pages = doc.pages;
    return Scaffold(
      appBar: AppBar(
        title: Text(doc.name, overflow: TextOverflow.ellipsis),
        actions: [
          IconButton(
            icon: const Icon(Icons.delete_outline),
            onPressed: () async {
              final ok = await showDialog<bool>(
                context: context,
                builder: (_) => AlertDialog(
                  title: const Text('Delete this scan?'),
                  actions: [
                    TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
                    TextButton(onPressed: () => Navigator.pop(context, true), child: const Text('Delete')),
                  ],
                ),
              );
              if (ok == true) {
                await doc.dir.delete(recursive: true);
                if (context.mounted) Navigator.pop(context);
              }
            },
          ),
        ],
      ),
      body: Column(children: [
        Expanded(
          child: ListView.builder(
            padding: const EdgeInsets.all(12),
            itemCount: pages.length,
            itemBuilder: (_, i) => Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: InteractiveViewer(child: Image.file(pages[i])),
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.all(12),
          child: Row(children: [
            Expanded(
              child: OutlinedButton.icon(
                onPressed: () => _share(context, watermark: true),
                icon: const Icon(Icons.picture_as_pdf),
                label: const Text('Share PDF'),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: FilledButton.icon(
                onPressed: () {
                  final shown = Ads.showRewarded(() => _share(context, watermark: false));
                  if (!shown) snack(context, 'Ad not ready yet. Try again in a moment.');
                },
                icon: const Icon(Icons.play_circle_outline),
                label: const Text('No watermark'),
              ),
            ),
          ]),
        ),
      ]),
      bottomNavigationBar: const BannerBox(),
    );
  }
}

// ===================== SCREEN 4: SETTINGS =====================
class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key});
  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('Settings')),
        body: ListView(children: [
          const ListTile(leading: Icon(Icons.lock_outline), title: Text('Privacy'), subtitle: Text('Your scans stay on this phone. No login, no cloud.')),
          ListTile(
            leading: const Icon(Icons.delete_sweep_outlined),
            title: const Text('Delete all scans'),
            onTap: () async {
              final ok = await showDialog<bool>(
                context: context,
                builder: (_) => AlertDialog(
                  title: const Text('Delete ALL scans?'),
                  content: const Text('This cannot be undone.'),
                  actions: [
                    TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
                    TextButton(onPressed: () => Navigator.pop(context, true), child: const Text('Delete all')),
                  ],
                ),
              );
              if (ok == true) {
                final d = await scansDir();
                await d.delete(recursive: true);
                if (context.mounted) snack(context, 'All scans deleted');
              }
            },
          ),
          const ListTile(leading: Icon(Icons.workspace_premium_outlined), title: Text('Premium'), subtitle: Text('Coming soon: no ads, no watermark')),
          const ListTile(leading: Icon(Icons.info_outline), title: Text('Version'), subtitle: Text('1.0.0')),
        ]),
        bottomNavigationBar: const BannerBox(),
      );
}
