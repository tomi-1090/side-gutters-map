import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart';
import 'package:file_picker/file_picker.dart';
import 'dart:convert';
import 'package:web/web.dart' as web;
import 'package:shared_preferences/shared_preferences.dart';
import 'dart:math' as math;
import 'package:http/http.dart' as http;
import 'package:flutter/services.dart';

void main() => runApp(const MyApp());

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return const MaterialApp(
      title: '側溝踏査マップ',
      home: MapPage(),
      debugShowCheckedModeBanner: false,
    );
  }
}

// ================================================================
// 定数
// ================================================================

const _kTileUrls = {
  'osm'      : 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
  'gsi_photo': 'https://cyberjapandata.gsi.go.jp/xyz/seamlessphoto/{z}/{x}/{y}.jpg',
};

const _kColorPalette = [
  Colors.blue, Colors.red, Colors.green, Colors.orange,
  Colors.purple, Colors.teal, Colors.brown, Colors.grey,
];

const _kShapeOptions = ['open', 'box', 'circle', 'other'];
const _kShapeLabels  = {
  'open': '開渠', 'box': 'BOX', 'circle': '円形', 'other': 'その他',
};

const _kDiameterOptions = [
  '300×300', '400×400', '500×500', '600×600',
  '700×700', '800×800', '900×900', '1000×1000',
  '300×400', '400×500', '500×600',
];

// localStorageキー
const _kStorageKey = 'layers_data';
const _kShareIdKey = 'share_id';

// ================================================================
// データモデル
// ================================================================

class GutterLayer {
  String id;
  String name;
  bool visible;
  List<Gutter> gutters;
  String? categoryKey;
  Map<String, Color> categoryColors;

  GutterLayer({
    required this.id,
    required this.name,
    this.visible = true,
    required this.gutters,
    this.categoryKey,
    Map<String, Color>? categoryColors,
  }) : categoryColors = categoryColors ?? {};

  Map<String, dynamic> toJson() => {
    'id'            : id,
    'name'          : name,
    'visible'       : visible,
    'gutters'       : gutters.map((g) => g.toJson()).toList(),
    'categoryKey'   : categoryKey,
    'categoryColors': categoryColors.map((k, v) => MapEntry(k, v.toARGB32())),
  };

  factory GutterLayer.fromJson(Map<String, dynamic> j) => GutterLayer(
    id      : j['id']?.toString()   ?? '',
    name    : j['name']?.toString() ?? '',
    visible : j['visible'] as bool? ?? true,
    gutters : (j['gutters'] as List<dynamic>? ?? [])
        .map((g) => Gutter.fromJson(g as Map<String, dynamic>))
        .toList(),
    categoryKey   : j['categoryKey']?.toString(),
    categoryColors: (j['categoryColors'] as Map<String, dynamic>? ?? {})
        .map((k, v) => MapEntry(k, Color(v as int))),
  );
}

class Gutter {
  String id;
  String name;
  String shape;
  String diameter;
  String memo;
  bool flowReversed;
  Color color;
  List<LatLng> points;
  Map<String, dynamic> properties;
  bool showArrow;
  double arrowSize;
  double strokeWidth;
  bool showHeadMark;
  double headMarkSize;

  Gutter({
    required this.id,
    this.name         = '',
    this.shape        = 'open',
    this.diameter     = '300×300',
    this.memo         = '',
    this.flowReversed = false,
    required this.points,
    Color? color,
    Map<String, dynamic>? properties,
    this.showArrow  = false,
    this.arrowSize  = 12.0,
    this.strokeWidth = 7.5,
    this.showHeadMark = false,
    this.headMarkSize = 10.0,
  })  : color      = color ?? Colors.blue,
        properties = properties ?? {};

  Map<String, dynamic> toJson() => {
    'id'          : id,
    'name'        : name,
    'shape'       : shape,
    'diameter'    : diameter,
    'memo'        : memo,
    'flowReversed': flowReversed,
    'color'       : color.toARGB32(),
    'points'      : points.map((p) => [p.longitude, p.latitude]).toList(),
    'properties'  : properties,
    'showArrow'   : showArrow,
    'arrowSize'   : arrowSize,
    'strokeWidth' : strokeWidth,
    'showHeadMark': showHeadMark,
    'headMarkSize': headMarkSize,
  };

  factory Gutter.fromJson(Map<String, dynamic> j) => Gutter(
    id          : j['id']?.toString()       ?? '',
    name        : j['name']?.toString()     ?? '',
    shape       : j['shape']?.toString()    ?? 'open',
    diameter    : j['diameter']?.toString() ?? '300×300',
    memo        : j['memo']?.toString()     ?? '',
    flowReversed: j['flowReversed'] as bool? ?? false,
    color       : Color(j['color'] as int?  ?? Colors.blue.toARGB32()),
    points      : (j['points'] as List<dynamic>)
        .map((e) => LatLng((e[1] as num).toDouble(), (e[0] as num).toDouble()))
        .toList(),
    properties  : Map<String, dynamic>.from(j['properties'] ?? {}),
    showArrow   : j['showArrow']   as bool? ?? false,
    arrowSize   : (j['arrowSize']   as num?)?.toDouble() ?? 12.0,
    strokeWidth : (j['strokeWidth'] as num?)?.toDouble() ?? 7.5,
    showHeadMark: j['showHeadMark'] as bool? ?? false,
    headMarkSize: (j['headMarkSize'] as num?)?.toDouble() ?? 10.0,
  );
}

// ================================================================
// ページ
// ================================================================

class MapPage extends StatefulWidget {
  const MapPage({super.key});

  @override
  State<MapPage> createState() => _MapPageState();
}

class _MapPageState extends State<MapPage> {
  final _mapController = MapController();
  final _distance      = const Distance();
  final _scaffoldKey   = GlobalKey<ScaffoldState>();

  List<GutterLayer> layers          = [];
  int?              selectedLayerIndex;

  bool         isAddingNew      = false;
  List<LatLng> newPoints        = [];
  bool         isCutting        = false;
  int          _newGutterCounter = 1;

  String  currentTile      = 'osm';
  String? _sharedGeoJsonUrl;          // キャッシュバスターなし Raw URL を保持

  // ================================================================
  // 初期化
  // ================================================================

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _init());
  }

  Future<void> _init() async {
    // URLパラメータから geojson= を取得（デコード済み）
    final geojsonParam = Uri.base.queryParameters['geojson'] ?? '';
    if (geojsonParam.isNotEmpty) {
      await _loadFromUrl(Uri.decodeComponent(geojsonParam), isShared: true);
    } else {
      await _loadFromLocalStorage();
    }
  }

  // ================================================================
  // ローカルストレージ（localStorage → SharedPreferences フォールバック）
  // ================================================================

  Future<void> _saveToLocalStorage() async {
    if (!mounted) return;
    final json = jsonEncode(layers.map((l) => l.toJson()).toList());

    // 1. web localStorage（高速・Web専用）
    try {
      web.window.localStorage.setItem(_kStorageKey, json);
    } catch (e) {
      debugPrint('localStorage save failed: $e');
    }

    // 2. SharedPreferences（フォールバック）
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_kStorageKey, json);
    } catch (e) {
      debugPrint('SharedPreferences save failed: $e');
    }
  }

  Future<void> _loadFromLocalStorage() async {
    String? data;

    // 1. web localStorage
    try {
      final v = web.window.localStorage.getItem(_kStorageKey);
      if (v != null && v.isNotEmpty) data = v;
    } catch (e) {
      debugPrint('localStorage load failed: $e');
    }

    // 2. SharedPreferences
    if (data == null || data.isEmpty) {
      try {
        final prefs = await SharedPreferences.getInstance();
        data = prefs.getString(_kStorageKey);
      } catch (e) {
        debugPrint('SharedPreferences load failed: $e');
      }
    }

    if (data == null || data.isEmpty) return;

    try {
      final parsed = (jsonDecode(data) as List<dynamic>)
          .map((j) => GutterLayer.fromJson(j as Map<String, dynamic>))
          .toList();
      if (mounted) setState(() => layers = parsed);
    } catch (e) {
      debugPrint('JSON parse error: $e');
    }
  }

  // ================================================================
  // GeoJSON パース（共通）
  // ================================================================

  List<Gutter> _parseGeoJsonFeatures(List<dynamic> features) {
    final result = <Gutter>[];
    for (final f in features) {
      final geometry = f['geometry'];
      if (geometry == null) continue;

      final List<dynamic> coords;
      switch (geometry['type'] as String?) {
        case 'LineString':
          coords = geometry['coordinates'] as List<dynamic>;
        case 'MultiLineString':
          coords = (geometry['coordinates'] as List)
              .expand((line) => line as List<dynamic>)
              .toList();
        default:
          continue;
      }

      final points = coords
          .map((c) => LatLng((c[1] as num).toDouble(), (c[0] as num).toDouble()))
          .toList();
      if (points.length < 2) continue;

      final props    = f['properties'] as Map<String, dynamic>? ?? {};
      final shape    = props['shape']?.toString()    ?? props['断面形状']?.toString() ?? 'open';
      final diameter = props['diameter']?.toString() ?? props['口径']?.toString()     ?? '300×300';
      final memo     = props['memo']?.toString()     ?? props['メモ']?.toString()     ?? '';

      result.add(Gutter(
        id          : props['id']?.toString()   ?? 'SG-1',
        name        : props['name']?.toString() ?? '',
        shape       : shape,
        diameter    : diameter,
        memo        : memo,
        flowReversed: props['flowReversed'] as bool? ?? false,
        color       : props['color'] != null ? Color(props['color'] as int) : Colors.blue,
        strokeWidth : (props['strokeWidth'] as num?)?.toDouble() ?? 7.5,
        showArrow   : props['showArrow'] as bool? ?? false,
        arrowSize   : (props['arrowSize'] as num?)?.toDouble() ?? 12.0,
        showHeadMark : props['showHeadMark'] as bool? ?? false,
        headMarkSize : (props['headMarkSize'] as num?)?.toDouble() ?? 10.0,
        points      : points,
        properties  : Map<String, dynamic>.from(props),
      ));
    }
    return result;
  }

  void _addParsedLayer(List<Gutter> gutters, String name) {
    if (gutters.isEmpty) return;
    setState(() {
      layers.add(GutterLayer(
        id     : DateTime.now().millisecondsSinceEpoch.toString(),
        name   : name,
        gutters: gutters,
      ));
    });
    _showAllGutters();
  }

  // ================================================================
  // GeoJSON 読み込み（URL）
  // ================================================================

  /// URL から GeoJSON を取得してレイヤーに追加する汎用メソッド。
  /// [isShared] = true のとき shareId を localStorage に保存し、
  /// アップロード時に同じファイルを上書きできるようにする。
  Future<void> _loadFromUrl(String rawUrl, {bool isShared = false}) async {
    // クエリパラメータをすべて除去して純粋な Raw URL を作る
    final cleanUrl = rawUrl.contains('?') ? rawUrl.split('?').first : rawUrl;

    // キャッシュバスターは fetch の cache オプションで対応できないため
    // スマホ対策として Pragma/Cache-Control ヘッダーを使う
    _showSnackBar(isShared ? '共有URLからデータを読み込み中...' : 'GeoJSONを読み込み中...');

    try {
      final response = await http.get(
        Uri.parse(cleanUrl),
        headers: {
          'Cache-Control': 'no-cache, no-store',
          'Pragma'       : 'no-cache',
        },
      );

      if (response.statusCode != 200) {
        throw Exception('HTTP ${response.statusCode}');
      }

      final data    = jsonDecode(utf8.decode(response.bodyBytes)) as Map<String, dynamic>;
      final gutters = _parseGeoJsonFeatures(data['features'] as List<dynamic>? ?? []);

      if (isShared) {
        // shareId を保存（次回アップロードで同ファイルを上書き）
        final shareId = Uri.parse(cleanUrl).pathSegments.last.replaceAll('.geojson', '');
        try {
          web.window.localStorage.setItem(_kShareIdKey, shareId);
        } catch (_) {}
        _sharedGeoJsonUrl = cleanUrl;
      }

      if (gutters.isEmpty) {
        _showSnackBar('有効なラインが見つかりませんでした');
        return;
      }

      final label = isShared
          ? '共有データ ${DateTime.now().toIso8601String().substring(0, 10)}'
          : 'URL読み込み ${layers.length + 1}';

      _addParsedLayer(gutters, label);
      if (isShared) await _saveToLocalStorage();
      _showSnackBar('${gutters.length}本の側溝を読み込みました');

    } catch (e) {
      _showSnackBar('読み込み失敗: $e');
      if (isShared) await _loadFromLocalStorage();
    }
  }

  // ================================================================
  // GeoJSON 読み込み（ファイル）
  // ================================================================

  Future<void> _loadGeoJSON() async {
    try {
      final result = await FilePicker.platform.pickFiles(
        type             : FileType.custom,
        allowedExtensions: ['geojson', 'json'],
        allowMultiple    : false,
      );
      if (result == null || result.files.isEmpty) return;

      final file    = result.files.first;
      final data    = jsonDecode(utf8.decode(file.bytes!)) as Map<String, dynamic>;
      final gutters = _parseGeoJsonFeatures(data['features'] as List<dynamic>? ?? []);

      if (gutters.isEmpty) {
        _showSnackBar('有効なラインがありませんでした');
        return;
      }

      final layerName = 'レイヤー ${layers.length + 1} - ${file.name}';
      _addParsedLayer(gutters, layerName);
      _showSnackBar('${gutters.length}件を「$layerName」に追加しました');

      Future.delayed(const Duration(milliseconds: 300), () {
        if (mounted) _scaffoldKey.currentState?.openEndDrawer();
      });
    } catch (e) {
      _showSnackBar('読み込みエラー: $e');
    }
  }

  // ================================================================
  // GeoJSON エクスポート（ダウンロード）
  // ================================================================

  void _exportGeoJSON() {
    try {
      final features = _buildFeatureList(withLayerMeta: false);
      if (features.isEmpty) {
        _showSnackBar('エクスポートするデータがありません');
        return;
      }

      final jsonStr = const JsonEncoder.withIndent('  ').convert({
        'type'       : 'FeatureCollection',
        'features'   : features,
        'exported_at': DateTime.now().toIso8601String(),
      });

      final anchor = web.HTMLAnchorElement()
        ..href     = 'data:application/geo+json;base64,${base64Encode(utf8.encode(jsonStr))}'
        ..download = 'sideGutters_${DateTime.now().toIso8601String().substring(0, 10)}.geojson';
      web.document.body!.append(anchor);
      anchor.click();
      anchor.remove();

      _showSnackBar('${features.length}件をエクスポートしました');
    } catch (e) {
      _showSnackBar('エクスポートエラー: $e');
    }
  }

  // ================================================================
  // GeoJSON アップロード（全レイヤー共有）
  // ================================================================

  Future<void> _uploadAllLayers() async {
    if (layers.isEmpty) {
      _showSnackBar('アップロードするデータがありません');
      return;
    }

    try {
      // shareId 決定（既存ファイルを上書き or 新規）
      String shareId;
      if (_sharedGeoJsonUrl != null) {
        shareId = Uri.parse(_sharedGeoJsonUrl!).pathSegments.last.replaceAll('.geojson', '');
      } else {
        try {
          shareId = web.window.localStorage.getItem(_kShareIdKey) ?? '';
          if (shareId.isEmpty) shareId = DateTime.now().millisecondsSinceEpoch.toString();
        } catch (_) {
          shareId = DateTime.now().millisecondsSinceEpoch.toString();
        }
      }

      final features = _buildFeatureList(withLayerMeta: true);
      final geojson  = {
        'type'        : 'FeatureCollection',
        'features'    : features,
        'exported_at' : DateTime.now().toIso8601String(),
        'layers_count': layers.length,
        'gutters_count': features.length,
      };

      final apiUrl  = '${web.window.location.origin}/api/uploadGeoJson';
      final response = await http.post(
        Uri.parse(apiUrl),
        headers: {'Content-Type': 'application/json'},
        body   : jsonEncode({'shareId': shareId, 'geojson': geojson}),
      );

      if (response.statusCode != 200) {
        throw Exception('HTTP ${response.statusCode}: ${response.body}');
      }

      final data      = jsonDecode(response.body) as Map<String, dynamic>;
      final rawUrl    = data['rawUrl'] as String;        // クエリなし Raw URL
      _sharedGeoJsonUrl = rawUrl;

      // shareId を保存（次回上書き用）
      try {
        web.window.localStorage.setItem(_kShareIdKey, data['shareId'] as String? ?? shareId);
      } catch (_) {}

      // 共有URL（キャッシュバスターなし）
      // スマホ対応: クエリパラメータを URL に含めない
      final shareUrl = '${web.window.location.origin}/?geojson=${Uri.encodeComponent(rawUrl)}';

      try {
        await Clipboard.setData(ClipboardData(text: shareUrl));
      } catch (_) {}

      if (!mounted) return;
      showDialog(
        context: context,
        builder: (_) => AlertDialog(
          title  : const Text('共有URL生成完了'),
          content: SelectableText(shareUrl),
          actions: [
            TextButton(
              onPressed: () => Clipboard.setData(ClipboardData(text: shareUrl)),
              child    : const Text('コピー'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(context),
              child    : const Text('閉じる'),
            ),
          ],
        ),
      );
      _showSnackBar('${features.length}本を共有しました');

    } catch (e) {
      _showSnackBar('アップロード失敗: $e');
    }
  }

  // ================================================================
  // 共有URL生成（手動でRaw URLを入力するパターン）
  // ================================================================

  void _generateShareUrl() => _showUrlInputDialog(
    title      : 'GeoJSON共有URL生成',
    hint       : 'https://raw.githubusercontent.com/...',
    actionLabel: '生成',
    onSubmit   : (geojsonUrl) {
      final shareUrl = '${web.window.location.origin}/?geojson=${Uri.encodeComponent(geojsonUrl)}';
      Clipboard.setData(ClipboardData(text: shareUrl));
      _showSnackBar('共有URLをコピーしました');
      if (!context.mounted) return;
      showDialog(
        context: context,
        builder: (_) => AlertDialog(
          title  : const Text('共有URL'),
          content: SelectableText(shareUrl),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child    : const Text('閉じる'),
            ),
          ],
        ),
      );
    },
  );

  // ================================================================
  // Feature リスト生成（エクスポート・アップロード共用）
  // ================================================================

  List<Map<String, dynamic>> _buildFeatureList({required bool withLayerMeta}) {
    return [
      for (final layer in layers)
        for (final g in layer.gutters)
          {
            'type'    : 'Feature',
            'geometry': {
              'type'       : 'LineString',
              'coordinates': g.points.map((p) => [p.longitude, p.latitude]).toList(),
            },
            'properties': {
              'id'  : g.id,
              'name': g.name,
              ...g.properties,
              if (withLayerMeta) ...{
                'layer'       : layer.name,
                'layerId'     : layer.id,
                'layerVisible': layer.visible,
                'shape'       : g.shape,
                'diameter'    : g.diameter,
                'memo'        : g.memo,
                'flowReversed': g.flowReversed,
                'color'       : g.color.toARGB32(),
                'strokeWidth' : g.strokeWidth,
                'showArrow'   : g.showArrow,
                'arrowSize'   : g.arrowSize,
                'showHeadMark' : g.showHeadMark,
                'headMarkSize' : g.headMarkSize, 
              },
            },
          },
    ];
  }

  // ================================================================
  // モード切り替え
  // ================================================================

  void _toggleAddMode() => setState(() {
    isAddingNew = !isAddingNew;
    isCutting   = false;
    newPoints.clear();
  });

  void _toggleCutMode() => setState(() {
    isCutting   = !isCutting;
    isAddingNew = false;
  });

  // ================================================================
  // マップタップ処理
  // ================================================================

  void _addPoint(TapPosition _, LatLng point) {
    final layer = _currentLayer;
    if (layer == null) {
      _showSnackBar('レイヤーがありません。先にGeoJSONを読み込んでください。');
      return;
    }

    if (isAddingNew) {
      setState(() => newPoints.add(point));
    } else if (isCutting) {
      _cutLineAtPoint(point, layer);
    } else {
      final nearest = _findNearestGutterInLayer(point, layer);
      if (nearest != null) _showGutterInfo(nearest);
    }
  }

  // ================================================================
  // 切断機能
  // ================================================================

  void _cutLineAtPoint(LatLng tapPoint, GutterLayer layer) {
    double  bestDist = double.infinity;
    int     bestIdx  = -1;
    int     bestSeg  = -1;
    LatLng? bestProj;

    for (int i = 0; i < layer.gutters.length; i++) {
      final pts = layer.gutters[i].points;
      if (pts.length < 2) continue;
      for (int j = 0; j < pts.length - 1; j++) {
        final proj = _projectOnSegment(tapPoint, pts[j], pts[j + 1]);
        final dist = _distance.distance(tapPoint, proj);
        if (dist < bestDist) {
          bestDist = dist;
          bestIdx  = i;
          bestSeg  = j;
          bestProj = proj;
        }
      }
    }

    if (bestIdx == -1 || bestDist >= 30 || bestProj == null) {
      _showSnackBar('ラインの近くをタップしてください');
      return;
    }

    final g    = layer.gutters[bestIdx];
    final pts  = g.points;
    final proj = bestProj;

    setState(() {
  layer.gutters.removeAt(bestIdx);

  layer.gutters.add(
    Gutter(
      id: '${g.id}-A',
      name: '${g.name}-A',

      shape: g.shape,
      diameter: g.diameter,
      memo: g.memo,
      flowReversed: g.flowReversed,

      color: g.color,

      showArrow: g.showArrow,
      arrowSize: g.arrowSize,
      strokeWidth: g.strokeWidth,

      showHeadMark: g.showHeadMark,
      headMarkSize: g.headMarkSize,

      properties: Map<String, dynamic>.from(g.properties),

      points: [
        ...pts.sublist(0, bestSeg + 1),
        proj,
      ],
    ),
  );

  layer.gutters.add(
    Gutter(
        id: '${g.id}-B',
        name: '${g.name}-B',

        shape: g.shape,
        diameter: g.diameter,
        memo: g.memo,
        flowReversed: g.flowReversed,

        color: g.color,

        showArrow: g.showArrow,
        arrowSize: g.arrowSize,
        strokeWidth: g.strokeWidth,

        showHeadMark: g.showHeadMark,
        headMarkSize: g.headMarkSize,

        properties: Map<String, dynamic>.from(g.properties),

        points: [
          proj,
          ...pts.sublist(bestSeg + 1),
        ],
      ),
    );
  });

    _saveToLocalStorage();
    _showSnackBar('切断完了 (${bestDist.toStringAsFixed(1)}m)');
  }

  LatLng _projectOnSegment(LatLng p, LatLng a, LatLng b) {
    final dx   = b.longitude - a.longitude;
    final dy   = b.latitude  - a.latitude;
    final len2 = dx * dx + dy * dy;
    if (len2 == 0) return a;
    final t  = ((p.longitude - a.longitude) * dx + (p.latitude - a.latitude) * dy) / len2;
    final tc = t.clamp(0.0, 1.0);
    return LatLng(a.latitude + tc * dy, a.longitude + tc * dx);
  }

  Gutter? _findNearestGutterInLayer(LatLng tapPoint, GutterLayer layer) {
    double  bestDist = double.infinity;
    Gutter? nearest;
    for (final g in layer.gutters) {
      if (g.points.length < 2) continue;
      for (int j = 0; j < g.points.length - 1; j++) {
        final dist = _distance.distance(
          tapPoint,
          _projectOnSegment(tapPoint, g.points[j], g.points[j + 1]),
        );
        if (dist < bestDist && dist < 25) {
          bestDist = dist;
          nearest  = g;
        }
      }
    }
    return nearest;
  }

  // ================================================================
  // 新規 Gutter 追加
  // ================================================================

  void _saveNewGutter() {
    if (newPoints.length < 2) {
      _showSnackBar('2点以上タップしてください');
      return;
    }
    final layer = _currentLayer;
    if (layer == null) {
      _showSnackBar('レイヤーが選択されていません');
      return;
    }

    final ctrl = TextEditingController(text: '側溝 SG-00$_newGutterCounter');
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title  : const Text('新規側溝保存'),
        content: TextField(
          controller: ctrl,
          decoration: const InputDecoration(labelText: '側溝名'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child    : const Text('キャンセル'),
          ),
          TextButton(
            onPressed: () {
              setState(() {
                layer.gutters.add(Gutter(
                  id    : 'SG-00$_newGutterCounter',
                  name  : ctrl.text,
                  points: List.from(newPoints),
                ));
                _newGutterCounter++;
                newPoints.clear();
                isAddingNew = false;
              });
              _saveToLocalStorage();
              _showSnackBar('「${layer.name}」に追加しました');
              Navigator.pop(ctx);
            },
            child: const Text('保存'),
          ),
        ],
      ),
    );
  }

  // ================================================================
  // Gutter 情報表示・編集
  // ================================================================

  void _showGutterInfo(Gutter g) {
    showModalBottomSheet(
      context          : context,
      isScrollControlled: true,
      useRootNavigator : true,
      shape            : const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => Padding(
        padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
        child: SingleChildScrollView(
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              mainAxisSize    : MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  g.name.isNotEmpty ? g.name : '側溝情報',
                  style: Theme.of(context).textTheme.titleLarge,
                ),
                const Divider(height: 24),
                Text('形状: ${_kShapeLabels[g.shape] ?? g.shape}'),
                const SizedBox(height: 8),
                Text('口径: ${g.diameter}'),
                const SizedBox(height: 8),
                Text('メモ: ${g.memo.isEmpty ? "なし" : g.memo}'),
                const SizedBox(height: 8),
                Text('流向矢印: ${g.showArrow ? "表示" : "非表示"}'),
                const SizedBox(height: 24),
                Row(
                  children: [
                    Expanded(
                      child: TextButton(
                        onPressed: () => Navigator.pop(ctx),
                        child    : const Text('閉じる'),
                      ),
                    ),
                    Expanded(
                      child: ElevatedButton(
                        onPressed: () {
                          Navigator.pop(ctx);
                          _showEditForm(g);
                        },
                        child: const Text('編集'),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
              ],
            ),
          ),
        ),
      ),
    );
  }

  void _showEditForm(Gutter g) {
    if (_currentLayer == null) return;

    final nameCtrl = TextEditingController(text: g.name);
    final shapeCtrl = TextEditingController(text: g.shape);
    final diamCtrl  = TextEditingController(text: g.diameter);
    final memCtrl   = TextEditingController(text: g.memo);

    showModalBottomSheet(
      context           : context,
      isScrollControlled: true,
      useRootNavigator  : true,
      backgroundColor   : Colors.white,
      shape             : const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => StatefulBuilder(
        builder: (context, setS) => Padding(
          padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
          child: SingleChildScrollView(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 20, 20, 30),
              child: Column(
                mainAxisSize    : MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('側溝編集 - ${g.id}',
                      style: Theme.of(context).textTheme.titleLarge),
                  const Divider(height: 24),

                  TextField(
                    controller: nameCtrl,
                    decoration: const InputDecoration(labelText: '名称'),
                  ),
                  const SizedBox(height: 16),

                  _buildAutocomplete(
                    label  : '断面形状',
                    hint   : '開渠 / BOX / 円形',
                    initial: g.shape,
                    options: _kShapeOptions,
                    display: (o) => _kShapeLabels[o] ?? o,
                    filter : (o, v) =>
                        o.toLowerCase().contains(v.toLowerCase()) ||
                        (_kShapeLabels[o] ?? '').contains(v),
                    ctrl   : shapeCtrl,
                  ),
                  const SizedBox(height: 16),

                  _buildAutocomplete(
                    label  : '口径',
                    hint   : '300×300 など',
                    initial: g.diameter,
                    options: _kDiameterOptions,
                    display: (o) => o,
                    filter : (o, v) => o.contains(v),
                    ctrl   : diamCtrl,
                  ),
                  const SizedBox(height: 16),

                  TextField(
                    controller: memCtrl,
                    maxLines  : 3,
                    decoration: const InputDecoration(
                      labelText: 'メモ',
                      border   : OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 12),

                  SwitchListTile.adaptive(
                    title: const Text('流向矢印を表示'),
                    value: g.showArrow,
                    onChanged: (v) => setS(() => g.showArrow = v),
                    contentPadding: EdgeInsets.zero,
                  ),

                  Align(
                    alignment: Alignment.centerLeft,
                    child: TextButton.icon(
                      icon: const Icon(Icons.swap_horiz),
                      label: const Text('流向を反転'),
                      onPressed: () async {
                        setState(() => g.points = g.points.reversed.toList());
                        await _saveToLocalStorage();
                        _showSnackBar('流向を反転しました');
                      },
                    ),
                  ),

                  SwitchListTile.adaptive(
                    title: const Text('最上流マークを表示'),
                    value: g.showHeadMark,
                    onChanged: (v) => setS(() => g.showHeadMark = v),
                    contentPadding: EdgeInsets.zero,
                  ),

                  const Divider(height: 32),
                  const Text('スタイル設定',
                      style: TextStyle(fontWeight: FontWeight.bold)),
                  const SizedBox(height: 12),

                  const Text('色'),
                  Wrap(
                    children: _kColorPalette.map((c) => GestureDetector(
                      onTap : () => setS(() => g.color = c),
                      child : Container(
                        width : 44,
                        height: 44,
                        margin: const EdgeInsets.all(5),
                        decoration: BoxDecoration(
                          color : c,
                          shape : BoxShape.circle,
                          border: Border.all(
                            color: g.color == c ? Colors.black : Colors.transparent,
                            width: 3,
                          ),
                        ),
                      ),
                    )).toList(),
                  ),
                  const SizedBox(height: 16),

                  const Text('線の太さ'),
                  Slider(
                    value    : g.strokeWidth,
                    min      : 3.0,
                    max      : 15.0,
                    divisions: 24,
                    label    : g.strokeWidth.toStringAsFixed(1),
                    onChanged: (v) => setS(() => g.strokeWidth = v),
                  ),

                  if (g.showArrow) ...[
                    const SizedBox(height: 12),
                    const Text('矢印サイズ'),
                    Slider(
                      value    : g.arrowSize,
                      min      : 5.0,
                      max      : 20.0,
                      divisions: 30,
                      label    : g.arrowSize.toStringAsFixed(1),
                      onChanged: (v) => setS(() => g.arrowSize = v),
                    ),
                  ],

                  const SizedBox(height: 40),

                  Row(
                    children: [
                      Expanded(
                        child: TextButton(
                          onPressed: () => Navigator.pop(ctx),
                          child    : const Text('キャンセル'),
                        ),
                      ),
                      Expanded(
                        child: ElevatedButton(
                          onPressed: () async {
                            setState(() {
                              g.name     = nameCtrl.text;
                              g.shape    = shapeCtrl.text.trim();
                              g.diameter = diamCtrl.text.trim();
                              g.memo     = memCtrl.text.trim();
                            });
                            await _saveToLocalStorage();
                            if (mounted) {
                              Navigator.pop(ctx);
                              _showSnackBar('保存しました');
                            }
                          },
                          child: const Text('保存'),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildAutocomplete({
    required String label,
    required String hint,
    required String initial,
    required List<String> options,
    required String Function(String) display,
    required bool Function(String option, String input) filter,
    required TextEditingController ctrl,
  }) {
    return Autocomplete<String>(
      initialValue        : TextEditingValue(text: initial),
      optionsBuilder      : (v) =>
          v.text.isEmpty ? options : options.where((o) => filter(o, v.text)),
      displayStringForOption: display,
      onSelected          : (s) => ctrl.text = s,
      fieldViewBuilder    : (context, fieldCtrl, focusNode, _) {
        ctrl.text = fieldCtrl.text;
        return TextFormField(
          controller: fieldCtrl,
          focusNode : focusNode,
          decoration: InputDecoration(
            labelText: label,
            border   : const OutlineInputBorder(),
            hintText : hint,
          ),
        );
      },
    );
  }

  // ================================================================
  // カメラ・位置情報
  // ================================================================

  void _showAllGutters() {
    final pts = layers
        .where((l) => l.visible)
        .expand((l) => l.gutters)
        .expand((g) => g.points)
        .toList();
    if (pts.isNotEmpty) {
      _mapController.fitCamera(CameraFit.bounds(
        bounds : LatLngBounds.fromPoints(pts),
        padding: const EdgeInsets.all(60),
      ));
    }
  }

  Future<void> _getCurrentLocation() async {
    try {
      final pos = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy      : LocationAccuracy.high,
          distanceFilter: 10,
        ),
      );
      _mapController.move(LatLng(pos.latitude, pos.longitude), 17.0);
    } catch (e) {
      _showSnackBar('位置情報取得失敗: $e');
    }
  }

  // ================================================================
  // レイヤー管理
  // ================================================================

  void _renameLayer(int index) {
    final ctrl = TextEditingController(text: layers[index].name);
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title  : const Text('レイヤー名変更'),
        content: TextField(controller: ctrl),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child    : const Text('キャンセル'),
          ),
          TextButton(
            onPressed: () {
              setState(() => layers[index].name = ctrl.text);
              _saveToLocalStorage();
              Navigator.pop(ctx);
            },
            child: const Text('保存'),
          ),
        ],
      ),
    );
  }

  void _createEmptyLayer() {
    setState(() {
      layers.add(GutterLayer(
        id     : DateTime.now().millisecondsSinceEpoch.toString(),
        name   : '新規レイヤー ${layers.length + 1}',
        gutters: [],
      ));
    });
    _saveToLocalStorage();
  }

  // ================================================================
  // カテゴリ色分け
  // ================================================================

  Color _getGutterColor(Gutter g, GutterLayer layer) {
    if (layer.categoryKey != null && layer.categoryColors.isNotEmpty) {
      final value = g.properties[layer.categoryKey!]?.toString() ?? '未分類';
      return layer.categoryColors[value] ?? Colors.grey;
    }
    return g.color;
  }

  GutterLayer? get _currentLayer {
    if (layers.isEmpty) return null;
    if (selectedLayerIndex != null && selectedLayerIndex! < layers.length) {
      return layers[selectedLayerIndex!];
    }
    return layers.first;
  }

  List<String> _getAllPropertyKeys(GutterLayer layer) =>
      ({for (final g in layer.gutters) ...g.properties.keys}.toList()..sort());

  List<String> _getUniqueValues(GutterLayer layer, String? key) {
    if (key == null) return [];
    return ({
      for (final g in layer.gutters) g.properties[key]?.toString() ?? '未分類',
    }.toList()..sort());
  }

  Map<String, Color> _generateCategoryColors(GutterLayer layer, String key) {
    final values  = _getUniqueValues(layer, key);
    final palette = [...Colors.primaries, Colors.brown, Colors.grey, Colors.pink, Colors.cyan];
    return {for (int i = 0; i < values.length; i++) values[i]: palette[i % palette.length]};
  }

  void _showCategoryStylingDialog(int layerIndex) {
    final layer     = layers[layerIndex];
    String?          selectedKey = layer.categoryKey;
    Map<String, Color> tempColors = Map.from(layer.categoryColors);

    showDialog(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setS) {
          final uniqueValues = _getUniqueValues(layer, selectedKey);
          return AlertDialog(
            title  : const Text('カテゴリによる色分け'),
            content: SizedBox(
              width : double.maxFinite,
              height: 480,
              child : Column(
                children: [
                  DropdownButton<String?>(
                    isExpanded: true,
                    hint      : const Text('分類する属性を選択'),
                    value     : selectedKey,
                    items     : [
                      const DropdownMenuItem(value: null, child: Text('無効（個別色を使う）')),
                      ..._getAllPropertyKeys(layer)
                          .map((k) => DropdownMenuItem(value: k, child: Text(k))),
                    ],
                    onChanged: (val) => setS(() {
                      selectedKey = val;
                      if (val != null) tempColors = _generateCategoryColors(layer, val);
                    }),
                  ),
                  const Divider(),
                  if (selectedKey != null)
                    Expanded(
                      child: ListView.builder(
                        itemCount  : uniqueValues.length,
                        itemBuilder: (context, i) {
                          final value = uniqueValues[i];
                          return ListTile(
                            title  : Text(value.isEmpty ? '（空）' : value),
                            trailing: GestureDetector(
                              onTap: () async {
                                final picked = await showDialog<Color>(
                                  context: context,
                                  builder: (dlg) => AlertDialog(
                                    title  : Text('色を選択: $value'),
                                    content: Wrap(
                                      children: Colors.primaries.map((c) => GestureDetector(
                                        onTap : () => Navigator.pop(dlg, c),
                                        child : Container(
                                          width : 48,
                                          height: 48,
                                          color : c,
                                          margin: const EdgeInsets.all(4),
                                        ),
                                      )).toList(),
                                    ),
                                  ),
                                );
                                if (picked != null) setS(() => tempColors[value] = picked);
                              },
                              child: Container(
                                width : 36,
                                height: 36,
                                decoration: BoxDecoration(
                                  color : tempColors[value] ?? Colors.grey,
                                  shape : BoxShape.circle,
                                  border: Border.all(color: Colors.black45),
                                ),
                              ),
                            ),
                          );
                        },
                      ),
                    ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child    : const Text('キャンセル'),
              ),
              TextButton(
                onPressed: () {
                  setState(() {
                    layer.categoryKey    = selectedKey;
                    layer.categoryColors = tempColors;
                  });
                  _saveToLocalStorage();
                  Navigator.pop(context);
                  _showSnackBar('色分け設定を適用しました');
                },
                child: const Text('適用'),
              ),
            ],
          );
        },
      ),
    );
  }

  // ================================================================
  // 流向矢印
  // ================================================================

  List<Polygon> _createFlowArrowPolygons() => [
    for (final layer in layers)
      if (layer.visible)
        for (final g in layer.gutters)
          if (g.showArrow && g.points.length >= 2)
            Polygon(
              points          : _arrowheadPoints(
                g.points[g.points.length - 2],
                g.points.last,
                sizeMeters: g.arrowSize,
              ),
              color           : _getGutterColor(g, layer),
              borderColor     : Colors.white,
              borderStrokeWidth: 1.5,
            ),
  ];

  List<LatLng> _arrowheadPoints(LatLng from, LatLng to, {double sizeMeters = 12.0}) {
    final dy = to.latitude  - from.latitude;
    final dx = to.longitude - from.longitude;

    const mPerDegLat = 111320.0;
    final mPerDegLon = mPerDegLat * math.cos(to.latitude * math.pi / 180);

    final vecY = dy * mPerDegLat;
    final vecX = dx * mPerDegLon;
    final len  = math.sqrt(vecX * vecX + vecY * vecY);
    if (len < 1e-6) return [to, to, to];

    // 進行方向の単位ベクトル (ux, uy) と垂直単位ベクトル (vx, vy)
    final ux = vecX / len;
    final uy = vecY / len;
    final vx = -uy;           // 垂直 x 成分（経度方向）
    final vy =  ux;           // 垂直 y 成分（緯度方向）

    final halfWidth = sizeMeters * math.tan(15.0 * math.pi / 180);

    // 底辺の中心: 先端(to)から進行方向の逆に sizeMeters
    final bx = -ux * sizeMeters;
    final by = -uy * sizeMeters;

    return [
      to,
      LatLng(to.latitude  + (by - vy * halfWidth) / mPerDegLat,
             to.longitude + (bx - vx * halfWidth) / mPerDegLon),
      LatLng(to.latitude  + (by + vy * halfWidth) / mPerDegLat,
             to.longitude + (bx + vx * halfWidth) / mPerDegLon),
    ];
  }

  // ================================================================
// 最上流マーク
// ================================================================

List<Polyline> _createHeadMarkPolylines() => [
  for (final layer in layers)
    if (layer.visible)
      for (final g in layer.gutters)
        if (g.showHeadMark && g.points.length >= 2)
          _buildHeadMark(g, layer),
];

Polyline _buildHeadMark(Gutter g, GutterLayer layer) {
  final p1 = g.points.first;
  final p2 = g.points[1];

  final dx = p2.longitude - p1.longitude;
  final dy = p2.latitude - p1.latitude;

  final len = math.sqrt(dx * dx + dy * dy);

  if (len == 0) {
    return Polyline(points: [p1, p1]);
  }

  // 垂直方向
  final vx = -dy / len;
  final vy = dx / len;

  final size = g.headMarkSize * 0.0000018;

  final a = LatLng(
    p1.latitude + vy * size,
    p1.longitude + vx * size,
  );

  final b = LatLng(
    p1.latitude - vy * size,
    p1.longitude - vx * size,
  );

  return Polyline(
    points: [a, b],
    color: _getGutterColor(g, layer),
    strokeWidth: g.strokeWidth * 0.7,
  );
}

  // ================================================================
  // ユーティリティ
  // ================================================================

  void _showSnackBar(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  void _showUrlInputDialog({
    required String title,
    required String hint,
    required String actionLabel,
    required void Function(String url) onSubmit,
  }) {
    final ctrl = TextEditingController();
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title  : Text(title),
        content: TextField(
          controller: ctrl,
          decoration: InputDecoration(hintText: hint),
          maxLines  : 3,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child    : const Text('キャンセル'),
          ),
          TextButton(
            onPressed: () {
              final url = ctrl.text.trim();
              if (url.isEmpty) return;
              Navigator.pop(ctx);
              onSubmit(url);
            },
            child: Text(actionLabel),
          ),
        ],
      ),
    );
  }

  // ================================================================
  // UI
  // ================================================================

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      key       : _scaffoldKey,
      appBar    : _buildAppBar(),
      body      : _buildMap(),
      endDrawer : _buildDrawer(),
      floatingActionButton: _buildFab(),
    );
  }

  AppBar _buildAppBar() => AppBar(
    title: Text(isAddingNew
        ? '新規追加モード'
        : isCutting
            ? '切断モード'
            : '側溝踏査マップ'),
    backgroundColor: isAddingNew
        ? Colors.orange
        : isCutting
            ? Colors.purple
            : Colors.blue,
    actions: [
      PopupMenuButton<String>(
        icon      : const Icon(Icons.layers),
        onSelected: (v) => setState(() => currentTile = v),
        itemBuilder: (_) => const [
          PopupMenuItem(value: 'osm',       child: Text('OpenStreetMap')),
          PopupMenuItem(value: 'gsi_photo', child: Text('航空写真')),
        ],
      ),
      IconButton(
        icon     : const Icon(Icons.menu),
        onPressed: () => _scaffoldKey.currentState?.openEndDrawer(),
      ),
    ],
  );

  Widget _buildMap() => FlutterMap(
    mapController: _mapController,
    options      : MapOptions(
      initialCenter: const LatLng(36.555, 139.882),
      initialZoom  : 17.0,
      onTap        : _addPoint,
    ),
    children: [
    TileLayer(
      urlTemplate: _kTileUrls[currentTile] ?? _kTileUrls['osm']!,
      userAgentPackageName: 'com.example.sideGutter_map',
    ),

    // 側溝ライン
    ...layers.where((l) => l.visible).map(
      (layer) => PolylineLayer(
        polylines: layer.gutters.map((g) => Polyline(
          points: g.points,
          color: _getGutterColor(g, layer),
          strokeWidth: g.strokeWidth,
          borderStrokeWidth: 2.5,
          borderColor: Colors.white,
        )).toList(),
      ),
    ),

    // 新規追加中ライン
    if (isAddingNew && newPoints.isNotEmpty)
      PolylineLayer(
        polylines: [
          Polyline(
            points: newPoints,
            color: Colors.orange,
            strokeWidth: 7.5,
          ),
        ],
      ),

    // 流向矢印
    ..._createFlowArrowPolygons().map(
      (p) => PolygonLayer(
        polygons: [p],
        polygonCulling: false,
      ),
    ),

    // 最上流マーク
    ..._createHeadMarkPolylines().map(
      (p) => PolylineLayer(
        polylines: [p],
      ),
    ),
  ],
  );

  Widget _buildDrawer() => Drawer(
    child: Column(
      children: [
        const DrawerHeader(
          decoration: BoxDecoration(color: Colors.blue),
          child     : Center(
            child: Text('レイヤー管理',
                style: TextStyle(color: Colors.white, fontSize: 20)),
          ),
        ),
        Expanded(
          child: ListView.builder(
            itemCount  : layers.length,
            itemBuilder: (context, index) {
              final layer = layers[index];
              return ListTile(
                leading: Checkbox(
                  value    : layer.visible,
                  onChanged: (v) => setState(() => layer.visible = v!),
                ),
                title   : Text(layer.name),
                subtitle: Text(
                  '${layer.gutters.length} 本'
                  '${layer.categoryKey != null ? " ・ ${layer.categoryKey}" : ""}',
                ),
                onTap: () {
                  setState(() => selectedLayerIndex = index);
                  Navigator.pop(context);
                },
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children    : [
                    IconButton(
                      icon     : const Icon(Icons.palette),
                      tooltip  : 'カテゴリ色分け設定',
                      onPressed: () => _showCategoryStylingDialog(index),
                    ),
                    IconButton(
                      icon     : const Icon(Icons.edit),
                      tooltip  : 'レイヤー名変更',
                      onPressed: () => _renameLayer(index),
                    ),
                    IconButton(
                      icon     : const Icon(Icons.delete),
                      tooltip  : 'レイヤー削除',
                      onPressed: () => showDialog(
                        context: context,
                        builder: (_) => AlertDialog(
                          title  : const Text('レイヤー削除'),
                          content: Text('「${layer.name}」を削除しますか？'),
                          actions: [
                            TextButton(
                              onPressed: () => Navigator.pop(context),
                              child    : const Text('キャンセル'),
                            ),
                            TextButton(
                              onPressed: () {
                                setState(() {
                                  layers.removeAt(index);
                                  if (selectedLayerIndex != null &&
                                      selectedLayerIndex! >= layers.length) {
                                    selectedLayerIndex =
                                        layers.isEmpty ? null : layers.length - 1;
                                  }
                                });
                                Navigator.pop(context);
                              },
                              child: const Text('削除'),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              );
            },
          ),
        ),
        const Divider(),
        ListTile(
          leading: const Icon(Icons.add),
          title  : const Text('新しい空レイヤー作成'),
          onTap  : _createEmptyLayer,
        ),
      ],
    ),
  );

  FloatingActionButton _fab({
    required String   tag,
    required IconData icon,
    required VoidCallback onPressed,
    Color? color,
    bool mini = false,
  }) =>
      FloatingActionButton(
        heroTag        : tag,
        mini           : mini,
        backgroundColor: color,
        onPressed      : onPressed,
        child          : Icon(icon),
      );

  Widget _buildFab() {
    final fabs = <Widget>[
      _fab(tag: 'all',  icon: Icons.fullscreen,  onPressed: _showAllGutters, mini: true),
      if (isAddingNew)
        _fab(tag: 'save', icon: Icons.save, onPressed: _saveNewGutter),
      _fab(
        tag      : 'cut',
        icon     : Icons.content_cut,
        onPressed: _toggleCutMode,
        color    : isCutting ? Colors.purple : null,
      ),
      _fab(
        tag      : 'add',
        icon     : isAddingNew ? Icons.close : Icons.add,
        onPressed: _toggleAddMode,
        color    : isAddingNew ? Colors.red : Colors.green,
      ),
      _fab(tag: 'location', icon: Icons.my_location,  onPressed: _getCurrentLocation),
      _fab(tag: 'load',     icon: Icons.upload_file,  onPressed: _loadGeoJSON),
      _fab(tag: 'export',   icon: Icons.download,     onPressed: _exportGeoJSON),
      _fab(
        tag      : 'url_load',
        icon     : Icons.link,
        onPressed: () => _showUrlInputDialog(
          title      : 'GeoJSON URLから読み込み',
          hint       : 'https://raw.githubusercontent.com/...',
          actionLabel: '読み込み',
          onSubmit   : (url) => _loadFromUrl(url),
        ),
      ),
      _fab(tag: 'share_url', icon: Icons.share,        onPressed: _generateShareUrl),
      _fab(tag: 'upload',    icon: Icons.cloud_upload,  onPressed: _uploadAllLayers),
    ];

    final spaced = <Widget>[];
    for (int i = 0; i < fabs.length; i++) {
      spaced.add(fabs[i]);
      if (i < fabs.length - 1) spaced.add(const SizedBox(height: 8));
    }

    return Column(mainAxisAlignment: MainAxisAlignment.end, children: spaced);
  }
}