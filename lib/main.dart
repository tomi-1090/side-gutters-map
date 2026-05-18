import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:flutter_map/flutter_map.dart';
import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart';
import 'package:file_picker/file_picker.dart';

import 'dart:convert';
import 'dart:math' as math;

import 'package:web/web.dart' as web;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:http/http.dart' as http;

void main() => runApp(const MyApp());

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: '側溝踏査マップ',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.blue),
        useMaterial3: true,
      ),
      home: const MapPage(),
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

const _kShapeOptions = ['開渠', 'BOX', '円形', 'その他'];
const _kShapeLabels = {
  'open': '開渠', 'box': 'BOX', 'circle': '円形', 'other': 'その他',
};

const _kDiameterOptions = [
  '300×300', '400×400', '500×500', '600×600',
  '700×700', '800×800', '900×900', '1000×1000',
  '300×400', '400×500', '500×600',
];

const _kStorageKey = 'layers_data';
const _kShareIdKey = 'share_id';

// Undo履歴上限
const _kUndoLimit = 20;

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
    this.showArrow    = false,
    this.arrowSize    = 12.0,
    this.strokeWidth  = 7.5,
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

  bool         isAddingNew  = false;
  List<LatLng> newPoints    = [];
  bool         isCutting    = false;
  bool         isDeleting   = false;

  // Undo / Redo（差分ではなくスナップショット。上限を絞ってメモリ節約）
  final List<String> _undoStack = [];
  final List<String> _redoStack = [];

  int    _newGutterCounter = 1;
  String currentTile       = 'osm';
  String? _sharedGeoJsonUrl;

  // ================================================================
  // 初期化
  // ================================================================

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _init());
  }

  Future<void> _init() async {
    final geojsonParam = Uri.base.queryParameters['geojson'] ?? '';
    if (geojsonParam.isNotEmpty) {
      await _loadFromUrl(Uri.decodeComponent(geojsonParam), isShared: true);
    } else {
      await _loadFromLocalStorage();
    }
  }

  // ================================================================
  // ローカルストレージ
  // ================================================================

  Future<void> _saveToLocalStorage() async {
    if (!mounted) return;
    final json = jsonEncode(layers.map((l) => l.toJson()).toList());
    try {
      web.window.localStorage.setItem(_kStorageKey, json);
    } catch (_) {}
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_kStorageKey, json);
    } catch (_) {}
  }

  Future<void> _loadFromLocalStorage() async {
    String? data;
    try {
      final v = web.window.localStorage.getItem(_kStorageKey);
      if (v != null && v.isNotEmpty) data = v;
    } catch (_) {}

    if (data == null || data.isEmpty) {
      try {
        final prefs = await SharedPreferences.getInstance();
        data = prefs.getString(_kStorageKey);
      } catch (_) {}
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
  // GeoJSON パース
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
        showHeadMark: props['showHeadMark'] as bool? ?? false,
        headMarkSize: (props['headMarkSize'] as num?)?.toDouble() ?? 10.0,
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

  Future<void> _loadFromUrl(String rawUrl, {bool isShared = false}) async {
    final cleanUrl = rawUrl.contains('?') ? rawUrl.split('?').first : rawUrl;

    _showSnackBar(isShared ? '共有URLからデータを読み込み中...' : 'GeoJSONを読み込み中...');

    try {
      // NetworkAssetBundle は dart:io の Platform._version を参照するため
      // Web（スマホ・シークレットモード含む）では動作しない。
      // http パッケージを使用してキャッシュバスター付きで取得する。
      final cacheBustedUrl = '$cleanUrl?t=${DateTime.now().millisecondsSinceEpoch}';
      final response = await http.get(
        Uri.parse(cacheBustedUrl),
        headers: {
          'Cache-Control': 'no-cache, no-store',
          'Pragma'       : 'no-cache',
        },
      );

      if (response.statusCode != 200) {
        throw Exception('HTTP ${response.statusCode}');
      }

      final jsonString = utf8.decode(response.bodyBytes);

      final data = jsonDecode(jsonString) as Map<String, dynamic>;
      final gutters = _parseGeoJsonFeatures(data['features'] as List<dynamic>? ?? []);

      if (isShared) {
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

      // インデントなしでデータ軽量化
      final jsonStr = jsonEncode({
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
        'type'         : 'FeatureCollection',
        'features'     : features,
        'exported_at'  : DateTime.now().toIso8601String(),
        'layers_count' : layers.length,
        'gutters_count': features.length,
      };

      final apiUrl   = '${web.window.location.origin}/api/uploadGeoJson';
      final response = await http.post(
        Uri.parse(apiUrl),
        headers: {'Content-Type': 'application/json'},
        body   : jsonEncode({'shareId': shareId, 'geojson': geojson}),
      );

      if (response.statusCode != 200) {
        throw Exception('HTTP ${response.statusCode}: ${response.body}');
      }

      final data   = jsonDecode(response.body) as Map<String, dynamic>;
      final rawUrl = data['rawUrl'] as String;
      _sharedGeoJsonUrl = rawUrl;

      try {
        web.window.localStorage.setItem(_kShareIdKey, data['shareId'] as String? ?? shareId);
      } catch (_) {}

      // /?geojson= パラメータで共有（キャッシュバスターなし）
      final shareUrl = '${web.window.location.origin}/?geojson=${Uri.encodeComponent(rawUrl)}';

      try {
        await Clipboard.setData(ClipboardData(text: shareUrl));
      } catch (_) {}

      if (!mounted) return;
      _showShareDialog(shareUrl);
      _showSnackBar('${features.length}本を共有しました');

    } catch (e) {
      _showSnackBar('アップロード失敗: $e');
    }
  }

  void _showShareDialog(String shareUrl) {
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        title  : const Text('共有URL生成完了'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('クリップボードにコピー済みです。', style: TextStyle(color: Colors.green)),
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color       : Colors.grey.shade100,
                borderRadius: BorderRadius.circular(8),
              ),
              child: SelectableText(
                shareUrl,
                style: const TextStyle(fontSize: 12),
              ),
            ),
          ],
        ),
        actions: [
          TextButton.icon(
            icon     : const Icon(Icons.copy),
            label    : const Text('再コピー'),
            onPressed: () => Clipboard.setData(ClipboardData(text: shareUrl)),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context),
            child    : const Text('閉じる'),
          ),
        ],
      ),
    );
  }

  // ================================================================
  // 共有URL生成（手動Raw URL入力）
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
      _showShareDialog(shareUrl);
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
              // 座標を小数点6桁に丸めてデータ軽量化（約11cm精度で十分）
              'coordinates': g.points.map((p) => [
                double.parse(p.longitude.toStringAsFixed(6)),
                double.parse(p.latitude.toStringAsFixed(6)),
              ]).toList(),
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
                'showHeadMark': g.showHeadMark,
                'headMarkSize': g.headMarkSize,
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
    isDeleting  = false;
    newPoints.clear();
  });

  void _toggleCutMode() => setState(() {
    isCutting   = !isCutting;
    isAddingNew = false;
    isDeleting  = false;
  });

  void _toggleDeleteMode() => setState(() {
    isDeleting  = !isDeleting;
    isAddingNew = false;
    isCutting   = false;
  });

  // ================================================================
  // Undo / Redo
  // ================================================================

  void _saveStateForUndo() {
    _undoStack.add(jsonEncode(layers.map((l) => l.toJson()).toList()));
    _redoStack.clear();
    if (_undoStack.length > _kUndoLimit) _undoStack.removeAt(0);
  }

  void _undo() {
    if (_undoStack.isEmpty) return;
    _redoStack.add(jsonEncode(layers.map((l) => l.toJson()).toList()));
    final prev = _undoStack.removeLast();
    setState(() {
      layers = (jsonDecode(prev) as List<dynamic>)
          .map((j) => GutterLayer.fromJson(j))
          .toList();
    });
    _saveToLocalStorage();
  }

  void _redo() {
    if (_redoStack.isEmpty) return;
    _undoStack.add(jsonEncode(layers.map((l) => l.toJson()).toList()));
    final next = _redoStack.removeLast();
    setState(() {
      layers = (jsonDecode(next) as List<dynamic>)
          .map((j) => GutterLayer.fromJson(j))
          .toList();
    });
    _saveToLocalStorage();
  }

  // ================================================================
  // マップタップ処理
  // ================================================================

  void _addPoint(TapPosition _, LatLng point) {
    final layer = _currentLayer;
    if (layer == null) {
      _showSnackBar('レイヤーがありません。先にGeoJSONを読み込んでください。');
      return;
    }

    if (isDeleting) {
      final nearest = _findNearestGutterInLayer(point, layer);
      if (nearest != null) {
        _saveStateForUndo();
        setState(() => layer.gutters.remove(nearest));
        _saveToLocalStorage();
        _showSnackBar('側溝を削除しました');
      }
      return;
    }

    if (isAddingNew) {
      setState(() => newPoints.add(point));
    } else if (isCutting) {
      _cutLineAtPoint(point, layer);
    } else {
      final nearest = _findNearestGutterInLayer(point, layer);
      if (nearest != null) _showEditForm(nearest);
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

    _saveStateForUndo();
    setState(() {
      layer.gutters.removeAt(bestIdx);
      layer.gutters.add(Gutter(
        id          : '${g.id}-A',
        name        : '${g.name}-A',
        shape       : g.shape,
        diameter    : g.diameter,
        memo        : g.memo,
        flowReversed: g.flowReversed,
        color       : g.color,
        showArrow   : g.showArrow,
        arrowSize   : g.arrowSize,
        strokeWidth : g.strokeWidth,
        showHeadMark: g.showHeadMark,
        headMarkSize: g.headMarkSize,
        properties  : Map<String, dynamic>.from(g.properties),
        points      : [...pts.sublist(0, bestSeg + 1), proj],
      ));
      layer.gutters.add(Gutter(
        id          : '${g.id}-B',
        name        : '${g.name}-B',
        shape       : g.shape,
        diameter    : g.diameter,
        memo        : g.memo,
        flowReversed: g.flowReversed,
        color       : g.color,
        showArrow   : g.showArrow,
        arrowSize   : g.arrowSize,
        strokeWidth : g.strokeWidth,
        showHeadMark: g.showHeadMark,
        headMarkSize: g.headMarkSize,
        properties  : Map<String, dynamic>.from(g.properties),
        points      : [proj, ...pts.sublist(bestSeg + 1)],
      ));
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
          FilledButton(
            onPressed: () {
              _saveStateForUndo();
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

  void _showEditForm(Gutter g) {
    if (_currentLayer == null) return;

    final nameCtrl  = TextEditingController(text: g.name);
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
          child: DraggableScrollableSheet(
            initialChildSize: 0.65,
            minChildSize    : 0.35,
            maxChildSize    : 0.92,
            expand          : false,
            builder         : (_, scrollCtrl) => SingleChildScrollView(
              controller: scrollCtrl,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(20, 4, 20, 32),
                child: Column(
                  mainAxisSize      : MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // ドラッグハンドル
                    Center(
                      child: Container(
                        width : 40,
                        height: 4,
                        margin: const EdgeInsets.symmetric(vertical: 10),
                        decoration: BoxDecoration(
                          color        : Colors.grey.shade300,
                          borderRadius : BorderRadius.circular(2),
                        ),
                      ),
                    ),

                    Row(
                      children: [
                        Expanded(
                          child: Text('側溝編集 - ${g.id}',
                              style: Theme.of(context).textTheme.titleMedium),
                        ),
                        IconButton(
                          icon     : const Icon(Icons.close),
                          onPressed: () => Navigator.pop(ctx),
                        ),
                      ],
                    ),
                    const Divider(height: 16),

                    TextField(
                      controller: nameCtrl,
                      decoration: const InputDecoration(
                        labelText  : '名称',
                        border     : OutlineInputBorder(),
                        isDense    : true,
                      ),
                    ),
                    const SizedBox(height: 14),

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
                    const SizedBox(height: 14),

                    _buildAutocomplete(
                      label  : '口径',
                      hint   : '300×300 など',
                      initial: g.diameter,
                      options: _kDiameterOptions,
                      display: (o) => o,
                      filter : (o, v) => o.contains(v),
                      ctrl   : diamCtrl,
                    ),
                    const SizedBox(height: 14),

                    TextField(
                      controller: memCtrl,
                      maxLines  : 2,
                      decoration: const InputDecoration(
                        labelText: 'メモ',
                        border   : OutlineInputBorder(),
                        isDense  : true,
                      ),
                    ),
                    const SizedBox(height: 12),

                    // スイッチ類をコンパクトに
                    _compactSwitch(
                      label: '流向矢印',
                      value: g.showArrow,
                      onChanged: (v) => setS(() => g.showArrow = v),
                    ),
                    _compactSwitch(
                      label: '最上流マーク',
                      value: g.showHeadMark,
                      onChanged: (v) => setS(() => g.showHeadMark = v),
                    ),

                    TextButton.icon(
                      icon     : const Icon(Icons.swap_horiz, size: 18),
                      label    : const Text('流向を反転'),
                      onPressed: () async {
                        _saveStateForUndo();
                        setState(() => g.points = g.points.reversed.toList());
                        await _saveToLocalStorage();
                        if (!mounted) return;
                        _showSnackBar('流向を反転しました');
                      },
                    ),

                    const Divider(height: 24),
                    const Text('スタイル',
                        style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
                    const SizedBox(height: 8),

                    // 色
                    Wrap(
                      spacing: 6,
                      children: _kColorPalette.map((c) => GestureDetector(
                        onTap : () => setS(() => g.color = c),
                        child : Container(
                          width : 40,
                          height: 40,
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
                    const SizedBox(height: 10),

                    Row(
                      children: [
                        const Text('太さ', style: TextStyle(fontSize: 13)),
                        Expanded(
                          child: Slider(
                            value    : g.strokeWidth,
                            min      : 3.0,
                            max      : 15.0,
                            divisions: 24,
                            label    : g.strokeWidth.toStringAsFixed(1),
                            onChanged: (v) => setS(() => g.strokeWidth = v),
                          ),
                        ),
                        Text(g.strokeWidth.toStringAsFixed(1),
                            style: const TextStyle(fontSize: 12)),
                      ],
                    ),

                    if (g.showArrow)
                      Row(
                        children: [
                          const Text('矢印', style: TextStyle(fontSize: 13)),
                          Expanded(
                            child: Slider(
                              value    : g.arrowSize,
                              min      : 5.0,
                              max      : 20.0,
                              divisions: 30,
                              label    : g.arrowSize.toStringAsFixed(1),
                              onChanged: (v) => setS(() => g.arrowSize = v),
                            ),
                          ),
                          Text(g.arrowSize.toStringAsFixed(1),
                              style: const TextStyle(fontSize: 12)),
                        ],
                      ),

                    const SizedBox(height: 24),

                    Row(
                      children: [
                        Expanded(
                          child: OutlinedButton(
                            onPressed: () => Navigator.pop(ctx),
                            child    : const Text('キャンセル'),
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: FilledButton(
                            onPressed: () async {
                              _saveStateForUndo();
                              setState(() {
                                g.name     = nameCtrl.text;
                                g.shape    = shapeCtrl.text.trim();
                                g.diameter = diamCtrl.text.trim();
                                g.memo     = memCtrl.text.trim();
                              });
                              await _saveToLocalStorage();
                              if (!ctx.mounted) return;
                              Navigator.pop(ctx);
                              if (!mounted) return;
                              _showSnackBar('保存しました');
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
      ),
    );
  }

  Widget _compactSwitch({
    required String label,
    required bool value,
    required ValueChanged<bool> onChanged,
  }) =>
      Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label, style: const TextStyle(fontSize: 14)),
          Switch.adaptive(value: value, onChanged: onChanged),
        ],
      );

  Widget _buildAutocomplete({
    required String label,
    required String hint,
    required String initial,
    required List<String> options,
    required String Function(String) display,
    required bool Function(String option, String input) filter,
    required TextEditingController ctrl,
  }) {
    return DropdownMenu<String>(
      controller      : ctrl,
      label           : Text(label),
      hintText        : hint,
      width           : double.infinity,
      enableSearch    : true,
      enableFilter    : true,
      initialSelection: initial.isEmpty ? null : initial,
      dropdownMenuEntries: options.map((o) => DropdownMenuEntry<String>(
        value: o,
        label: display(o),
      )).toList(),
      onSelected: (value) {
        if (value != null) ctrl.text = value;
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
          FilledButton(
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
    final layer              = layers[layerIndex];
    String?            selectedKey = layer.categoryKey;
    Map<String, Color> tempColors  = Map.from(layer.categoryColors);

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
              FilledButton(
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
              points           : _arrowheadPoints(
                g.points[g.points.length - 2],
                g.points.last,
                sizeMeters: g.arrowSize,
              ),
              color            : _getGutterColor(g, layer),
              borderColor      : Colors.white,
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

    final ux = vecX / len;
    final uy = vecY / len;
    final vx = -uy;
    final vy =  ux;

    final halfWidth = sizeMeters * math.tan(15.0 * math.pi / 180);
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
    final dy = p2.latitude  - p1.latitude;

    const mPerDegLat = 111320.0;
    final mPerDegLon = mPerDegLat * math.cos(p1.latitude * math.pi / 180);

    final vecX = dx * mPerDegLon;
    final vecY = dy * mPerDegLat;
    final len  = math.sqrt(vecX * vecX + vecY * vecY);

    if (len < 1e-6) return Polyline(points: [p1, p1]);

    final vx   = -vecY / len;
    final vy   =  vecX / len;
    final size = g.headMarkSize * 0.35;

    return Polyline(
      points: [
        LatLng(p1.latitude + (vy * size) / mPerDegLat,
               p1.longitude + (vx * size) / mPerDegLon),
        LatLng(p1.latitude - (vy * size) / mPerDegLat,
               p1.longitude - (vx * size) / mPerDegLon),
      ],
      color      : _getGutterColor(g, layer).withValues(alpha: 0.9),
      strokeWidth: math.max(1.4, g.strokeWidth * 0.22),
    );
  }

  // ================================================================
  // ユーティリティ
  // ================================================================

  void _showSnackBar(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content        : Text(message),
        behavior       : SnackBarBehavior.floating,
        duration       : const Duration(seconds: 2),
        margin         : const EdgeInsets.fromLTRB(16, 0, 16, 80),
      ),
    );
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
          keyboardType: TextInputType.url,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child    : const Text('キャンセル'),
          ),
          FilledButton(
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
      key      : _scaffoldKey,
      appBar   : _buildAppBar(),
      body     : _buildBody(),
      endDrawer: _buildDrawer(),
    );
  }

  AppBar _buildAppBar() => AppBar(
    title: Text(
      isAddingNew
          ? '新規追加モード（${newPoints.length}点）'
          : isCutting
              ? '切断モード'
              : isDeleting
                  ? '削除モード'
                  : '側溝踏査マップ',
      style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
    ),
    backgroundColor: isAddingNew
        ? Colors.orange
        : isCutting
            ? Colors.purple
            : isDeleting
                ? Colors.red
                : Colors.blue,
    foregroundColor: Colors.white,
    actions: [
      // Undo / Redo
      IconButton(
        icon     : const Icon(Icons.undo),
        tooltip  : '元に戻す',
        onPressed: _undoStack.isEmpty ? null : _undo,
      ),
      IconButton(
        icon     : const Icon(Icons.redo),
        tooltip  : 'やり直す',
        onPressed: _redoStack.isEmpty ? null : _redo,
      ),
      // タイル切替
      PopupMenuButton<String>(
        icon      : const Icon(Icons.layers),
        tooltip   : '地図切替',
        onSelected: (v) => setState(() => currentTile = v),
        itemBuilder: (_) => const [
          PopupMenuItem(value: 'osm',       child: Text('OpenStreetMap')),
          PopupMenuItem(value: 'gsi_photo', child: Text('航空写真')),
        ],
      ),
      // メニュー（ドロワー）
      IconButton(
        icon     : const Icon(Icons.menu),
        tooltip  : 'レイヤー管理',
        onPressed: () => _scaffoldKey.currentState?.openEndDrawer(),
      ),
    ],
  );

  Widget _buildBody() => Stack(
    children: [
      _buildMap(),
      // モード中の操作ガイド（画面上部に薄く表示）
      if (isAddingNew || isCutting || isDeleting)
        Positioned(
          top  : 0,
          left : 0,
          right: 0,
          child: Container(
            color: (isAddingNew
                    ? Colors.orange
                    : isCutting
                        ? Colors.purple
                        : Colors.red)
                .withValues(alpha: 0.85),
            padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 12),
            child: Text(
              isAddingNew
                  ? '地図をタップして点を追加 → ✔で保存'
                  : isCutting
                      ? 'ラインをタップして切断'
                      : '削除したいラインをタップ',
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.white, fontSize: 13),
            ),
          ),
        ),
      // 右下 FAB エリア
      Positioned(
        right : 12,
        bottom: 24,
        child : _buildFabColumn(),
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
        urlTemplate        : _kTileUrls[currentTile] ?? _kTileUrls['osm']!,
        userAgentPackageName: 'com.example.sideGutter_map',
      ),
      ...layers.where((l) => l.visible).map(
        (layer) => PolylineLayer(
          polylines: layer.gutters.map((g) => Polyline(
            points          : g.points,
            color           : _getGutterColor(g, layer),
            strokeWidth     : g.strokeWidth,
            borderStrokeWidth: 2.5,
            borderColor     : Colors.white,
          )).toList(),
        ),
      ),
      if (isAddingNew && newPoints.isNotEmpty)
        PolylineLayer(
          polylines: [
            Polyline(points: newPoints, color: Colors.orange, strokeWidth: 7.5),
          ],
        ),
      ..._createFlowArrowPolygons().map(
        (p) => PolygonLayer(polygons: [p], polygonCulling: false),
      ),
      ..._createHeadMarkPolylines().map(
        (p) => PolylineLayer(polylines: [p]),
      ),
    ],
  );

  // ================================================================
  // FAB：スマホ向けに2列グリッド＋展開メニュー方式
  // ================================================================

  bool _fabExpanded = false;

  Widget _buildFabColumn() {
    return Column(
      mainAxisSize     : MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        // ── 展開時のサブメニュー ──────────────────────────────────
        if (_fabExpanded) ...[
          _menuRow(
            label  : 'ファイル読込',
            icon   : Icons.upload_file,
            onTap  : () { setState(() => _fabExpanded = false); _loadGeoJSON(); },
          ),
          _menuRow(
            label  : 'URL読込',
            icon   : Icons.link,
            onTap  : () {
              setState(() => _fabExpanded = false);
              _showUrlInputDialog(
                title      : 'GeoJSON URLから読み込み',
                hint       : 'https://raw.githubusercontent.com/...',
                actionLabel: '読み込み',
                onSubmit   : (url) => _loadFromUrl(url),
              );
            },
          ),
          _menuRow(
            label  : 'エクスポート',
            icon   : Icons.download,
            onTap  : () { setState(() => _fabExpanded = false); _exportGeoJSON(); },
          ),
          _menuRow(
            label  : 'アップロード共有',
            icon   : Icons.cloud_upload,
            onTap  : () { setState(() => _fabExpanded = false); _uploadAllLayers(); },
          ),
          _menuRow(
            label  : 'URL共有生成',
            icon   : Icons.share,
            onTap  : () { setState(() => _fabExpanded = false); _generateShareUrl(); },
          ),
          _menuRow(
            label  : '全体表示',
            icon   : Icons.fullscreen,
            onTap  : () { setState(() => _fabExpanded = false); _showAllGutters(); },
          ),
          const SizedBox(height: 4),
          const Divider(height: 1),
          const SizedBox(height: 4),
        ],

        // ── 常時表示のメインボタン群 ──────────────────────────────
        // 現在地
        _roundFab(
          icon   : Icons.my_location,
          tooltip: '現在地',
          onTap  : _getCurrentLocation,
          color  : Colors.white,
          iconColor: Colors.blue,
          mini   : true,
        ),
        const SizedBox(height: 6),

        // 削除モード
        _roundFab(
          icon     : Icons.delete_outline,
          tooltip  : '削除モード',
          onTap    : _toggleDeleteMode,
          color    : isDeleting ? Colors.red : Colors.white,
          iconColor: isDeleting ? Colors.white : Colors.red,
          mini     : true,
        ),
        const SizedBox(height: 6),

        // 切断モード
        _roundFab(
          icon     : Icons.content_cut,
          tooltip  : '切断モード',
          onTap    : _toggleCutMode,
          color    : isCutting ? Colors.purple : Colors.white,
          iconColor: isCutting ? Colors.white : Colors.purple,
          mini     : true,
        ),
        const SizedBox(height: 6),

        // 追加モード中は「保存」ボタンも表示
        if (isAddingNew) ...[
          _roundFab(
            icon     : Icons.check,
            tooltip  : '側溝を保存',
            onTap    : _saveNewGutter,
            color    : Colors.green,
            iconColor: Colors.white,
          ),
          const SizedBox(height: 6),
        ],

        // 追加 / キャンセル
        _roundFab(
          icon     : isAddingNew ? Icons.close : Icons.add,
          tooltip  : isAddingNew ? 'キャンセル' : '新規追加',
          onTap    : _toggleAddMode,
          color    : isAddingNew ? Colors.red : Colors.green,
          iconColor: Colors.white,
        ),
        const SizedBox(height: 6),

        // その他メニュー展開
        FloatingActionButton(
          heroTag        : 'menu_expand',
          backgroundColor: _fabExpanded ? Colors.blueGrey : Colors.blue,
          foregroundColor: Colors.white,
          onPressed      : () => setState(() => _fabExpanded = !_fabExpanded),
          child          : Icon(_fabExpanded ? Icons.close : Icons.more_vert),
        ),
      ],
    );
  }

  Widget _roundFab({
    required IconData icon,
    required String   tooltip,
    required VoidCallback onTap,
    required Color    color,
    required Color    iconColor,
    bool mini = false,
  }) =>
      FloatingActionButton(
        heroTag        : tooltip,
        mini           : mini,
        backgroundColor: color,
        foregroundColor: iconColor,
        tooltip        : tooltip,
        elevation      : 2,
        onPressed      : onTap,
        child          : Icon(icon, size: mini ? 20 : 24),
      );

  // 展開メニューの行アイテム
  Widget _menuRow({
    required String label,
    required IconData icon,
    required VoidCallback onTap,
  }) =>
      Padding(
        padding: const EdgeInsets.symmetric(vertical: 3),
        child: Row(
          mainAxisSize    : MainAxisSize.min,
          mainAxisAlignment: MainAxisAlignment.end,
          children: [
            Container(
              padding   : const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              decoration: BoxDecoration(
                color        : Colors.black54,
                borderRadius : BorderRadius.circular(8),
              ),
              child: Text(label,
                  style: const TextStyle(color: Colors.white, fontSize: 13)),
            ),
            const SizedBox(width: 8),
            FloatingActionButton.small(
              heroTag        : label,
              backgroundColor: Colors.white,
              foregroundColor: Colors.blueGrey.shade800,
              elevation      : 2,
              onPressed      : onTap,
              child          : Icon(icon, size: 20),
            ),
          ],
        ),
      );

  // ================================================================
  // ドロワー（レイヤー管理）
  // ================================================================

  Widget _buildDrawer() => Drawer(
    child: Column(
      children: [
        DrawerHeader(
          decoration: BoxDecoration(color: Theme.of(context).colorScheme.primary),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisAlignment : MainAxisAlignment.end,
            children: [
              const Text('レイヤー管理',
                  style: TextStyle(color: Colors.white, fontSize: 20, fontWeight: FontWeight.bold)),
              const SizedBox(height: 4),
              Text('${layers.length} レイヤー',
                  style: const TextStyle(color: Colors.white70, fontSize: 13)),
            ],
          ),
        ),
        Expanded(
          child: layers.isEmpty
              ? const Center(child: Text('レイヤーがありません\nGeoJSONを読み込んでください',
                  textAlign: TextAlign.center))
              : ReorderableListView.builder(
                  itemCount  : layers.length,
                  onReorder  : (oldIndex, newIndex) {
                    setState(() {
                      if (newIndex > oldIndex) newIndex--;
                      final item = layers.removeAt(oldIndex);
                      layers.insert(newIndex, item);
                    });
                    _saveToLocalStorage();
                  },
                  itemBuilder: (context, index) {
                    final layer = layers[index];
                    return ListTile(
                      key    : ValueKey(layer.id),
                      dense  : true,
                      leading: Checkbox(
                        value    : layer.visible,
                        onChanged: (v) {
                          setState(() => layer.visible = v!);
                          _saveToLocalStorage();
                        },
                      ),
                      title  : Text(layer.name,
                          style: TextStyle(
                            fontWeight: selectedLayerIndex == index
                                ? FontWeight.bold
                                : FontWeight.normal,
                          )),
                      subtitle: Text(
                        '${layer.gutters.length} 本'
                        '${layer.categoryKey != null ? " ・ ${layer.categoryKey}" : ""}',
                        style: const TextStyle(fontSize: 12),
                      ),
                      selected   : selectedLayerIndex == index,
                      selectedTileColor: Colors.blue.withValues(alpha: 0.08),
                      onTap  : () {
                        setState(() => selectedLayerIndex = index);
                        Navigator.pop(context);
                      },
                      trailing: Row(
                        mainAxisSize: MainAxisSize.min,
                        children    : [
                          IconButton(
                            icon     : const Icon(Icons.palette, size: 20),
                            tooltip  : 'カテゴリ色分け',
                            onPressed: () => _showCategoryStylingDialog(index),
                          ),
                          IconButton(
                            icon     : const Icon(Icons.edit, size: 20),
                            tooltip  : '名称変更',
                            onPressed: () => _renameLayer(index),
                          ),
                          IconButton(
                            icon     : const Icon(Icons.delete, size: 20, color: Colors.red),
                            tooltip  : '削除',
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
                                  FilledButton(
                                    style    : FilledButton.styleFrom(backgroundColor: Colors.red),
                                    onPressed: () {
                                      setState(() {
                                        layers.removeAt(index);
                                        if (selectedLayerIndex != null &&
                                            selectedLayerIndex! >= layers.length) {
                                          selectedLayerIndex =
                                              layers.isEmpty ? null : layers.length - 1;
                                        }
                                      });
                                      _saveToLocalStorage();
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
        const Divider(height: 1),
        SafeArea(
          child: ListTile(
            leading: const Icon(Icons.add_circle_outline),
            title  : const Text('新しい空レイヤー作成'),
            onTap  : () {
              _createEmptyLayer();
              Navigator.pop(context);
            },
          ),
        ),
      ],
    ),
  );
}