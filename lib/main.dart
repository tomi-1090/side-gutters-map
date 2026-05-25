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
  'osm'           : 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
  'google_photo'  : 'https://mt1.google.com/vt/lyrs=s&x={x}&y={y}&z={z}',
  'google_hybrid' : 'https://mt1.google.com/vt/lyrs=y&x={x}&y={y}&z={z}',
};

// タイル選択肢の表示ラベル
const _kTileLabels = {
  'osm'           : 'OpenStreetMap',
  'google_photo'  : '航空写真（Google）',
  'google_hybrid' : 'ハイブリッド（Google）',
};

// タイルごとのネイティブズーム上限
const _kTileMaxNativeZoom = {
  'osm'           : 19,
  'google_photo'  : 23,
  'google_hybrid' : 23,
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
const _kShareRawUrlKey = 'share_raw_url';

// Undo履歴上限
const _kUndoLimit = 20;

// GeoJSONプロパティキー → 日本語表示名マッピング
// カテゴリ色分けダイアログの属性選択ドロップダウンで使用
const _kPropKeyLabels = <String, String>{
  'shape'          : '断面形状',
  'diameter'       : '管径・口径',
  'memo'           : 'メモ',
  'name'           : '名称',
  'id'             : 'ID',
  'layer'          : 'レイヤー名',
  'layerId'        : 'レイヤーID',
  'layerVisible'   : 'レイヤー表示',
  'color'          : '色',
  'strokeWidth'    : '線幅',
  'showArrow'      : '流向矢印（ライン末端）',
  'arrowSize'      : '流向矢印サイズ',
  'showHeadMark'   : '最上流マーク',
  'headMarkSize'   : 'マークサイズ',
  // 外部GeoJSONでよく使われる日本語キーもそのまま通す
  '断面形状'       : '断面形状',
  '口径'           : '管径・口径',
};

// ================================================================
// 勾配矢印
// ================================================================
class ArrowStamp {
  String id;
  LatLng position;
  double angleDeg;   // 北を0°として時計回り

  ArrowStamp({
    required this.id,
    required this.position,
    required this.angleDeg,
  });

  Map<String, dynamic> toJson() => {
    'id': id,
    'lat': position.latitude,
    'lng': position.longitude,
    'angleDeg': angleDeg,
  };

  /// GeoJSON Feature（Point）として出力
  Map<String, dynamic> toGeoJsonFeature({String layerName = '', String layerId = ''}) => {
    'type'    : 'Feature',
    'geometry': {
      'type'       : 'Point',
      'coordinates': [
        double.parse(position.longitude.toStringAsFixed(6)),
        double.parse(position.latitude.toStringAsFixed(6)),
      ],
    },
    'properties': {
      'id'       : id,
      'type'     : 'arrow_stamp',
      'angleDeg' : angleDeg,
      'color'    : Colors.green.toARGB32(),
      if (layerName.isNotEmpty) 'layer'  : layerName,
      if (layerId.isNotEmpty)   'layerId': layerId,
    },
  };

  factory ArrowStamp.fromJson(Map<String, dynamic> j) => ArrowStamp(
    id: j['id']?.toString() ?? '',
    position: LatLng(
      (j['lat'] as num).toDouble(),
      (j['lng'] as num).toDouble(),
    ),
    angleDeg: (j['angleDeg'] as num?)?.toDouble() ?? 0.0,
  );
}
// ================================================================
// データモデル
// ================================================================

class GutterLayer {
  String id;
  String name;
  bool visible;
  List<Gutter> gutters;
  List<ArrowStamp> stamps;
  String? categoryKey;
  Map<String, Color> categoryColors;

  GutterLayer({
    required this.id,
    required this.name,
    this.visible = true,
    required this.gutters,
    List<ArrowStamp>? stamps,
    this.categoryKey,
    Map<String, Color>? categoryColors,
  }) : stamps = stamps ?? [],
       categoryColors = categoryColors ?? {};

  Map<String, dynamic> toJson() => {
    'id'            : id,
    'name'          : name,
    'visible'       : visible,
    'gutters'       : gutters.map((g) => g.toJson()).toList(),
    'stamps'        : stamps.map((s) => s.toJson()).toList(),
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
    stamps  : (j['stamps'] as List<dynamic>? ?? [])
        .map((s) => ArrowStamp.fromJson(s as Map<String, dynamic>))
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
    this.shape        = '---',
    this.diameter     = '---',
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
    'id'            : id,
    'name'          : name,
    'shape'         : shape,
    'diameter'      : diameter,
    'memo'          : memo,
    'flowReversed'  : flowReversed,
    'color'         : color.toARGB32(),
    'points'        : points.map((p) => [p.longitude, p.latitude]).toList(),
    'properties'    : properties,
    'showArrow'     : showArrow,
    'arrowSize'     : arrowSize,
    'strokeWidth'   : strokeWidth,
    'showHeadMark'  : showHeadMark,
    'headMarkSize'  : headMarkSize,
  };

  factory Gutter.fromJson(Map<String, dynamic> j) => Gutter(
    id             : j['id']?.toString()       ?? '',
    name           : j['name']?.toString()     ?? '',
    shape          : j['shape']?.toString()    ?? '---',
    diameter       : j['diameter']?.toString() ?? '---',
    memo           : j['memo']?.toString()     ?? '',
    flowReversed   : j['flowReversed'] as bool? ?? false,
    color          : Color(j['color'] as int?  ?? Colors.blue.toARGB32()),
    points         : (j['points'] as List<dynamic>)
        .map((e) => LatLng((e[1] as num).toDouble(), (e[0] as num).toDouble()))
        .toList(),
    properties     : Map<String, dynamic>.from(j['properties'] ?? {}),
    showArrow      : j['showArrow']   as bool? ?? false,
    arrowSize      : (j['arrowSize']   as num?)?.toDouble() ?? 12.0,
    strokeWidth    : (j['strokeWidth'] as num?)?.toDouble() ?? 7.5,
    showHeadMark   : j['showHeadMark'] as bool? ?? false,
    headMarkSize   : (j['headMarkSize'] as num?)?.toDouble() ?? 10.0,
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

  // モード関連
  bool isAddingNew = false;
  List<LatLng> newPoints = [];
  bool isCutting = false;
  bool isDeleting = false;
  bool isStamp2Pt = false;        // 2点指定のみ使用
  LatLng? _stamp2PtFirst;

  // Undo / Redo
  final List<String> _undoStack = [];
  final List<String> _redoStack = [];

  int    _newGutterCounter = 1;
  String currentTile       = 'google_photo'; // デフォルトは航空写真
  String? _sharedGeoJsonUrl;

  // ズームレベルに応じた線幅スケーリング用
  double _currentZoom = 17.0;

  // 端点スナップ ON/OFF（変更しないため final）
  final bool _snapEnabled = true;
  static const _kSnapRadiusM = 3.0; // スナップ判定距離（メートル）

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
      // URLパラメータがある場合はそこから読み込み、rawUrlも記憶
      await _loadFromUrl(Uri.decodeComponent(geojsonParam), isShared: true);
    } else {
      // URLパラメータがない場合：rawUrlをlocalStorageから復元してデータ読み込み
      try {
        final savedRawUrl = web.window.localStorage.getItem(_kShareRawUrlKey) ?? '';
        if (savedRawUrl.isNotEmpty) {
          _sharedGeoJsonUrl = savedRawUrl;
        }
      } catch (_) {}
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

  /// GeoJSON features からラインデータ（Gutter）を抽出。
  /// Pointフィーチャーはスキップ（ArrowStamp として別途 _parseArrowStampFeatures で処理）。
  List<Gutter> _parseGeoJsonFeatures(List<dynamic> features) {
    final result = <Gutter>[];
    for (final f in features) {
      final geometry = f['geometry'];
      if (geometry == null) continue;

      // Pointフィーチャーは ArrowStamp 用なのでスキップ
      final geoType = geometry['type'] as String?;
      if (geoType == 'Point') continue;

      final List<dynamic> coords;
      switch (geoType) {
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
      final shape    = props['shape']?.toString()    ?? props['断面形状']?.toString() ?? '---';
      final diameter = props['diameter']?.toString() ?? props['口径']?.toString()     ?? '---';
      final memo     = props['memo']?.toString()     ?? props['メモ']?.toString()     ?? '';

      // propertiesに shape/diameter/memo を必ず統一キーで書き込む
      // （外部GeoJSONが別キー名を使っていてもカテゴリ色分けで拾えるように）
      final mergedProps = Map<String, dynamic>.from(props);
      mergedProps['shape']    = shape;
      mergedProps['diameter'] = diameter;
      mergedProps['memo']     = memo;

      result.add(Gutter(
        id          : props['id']?.toString()   ?? 'SG-${DateTime.now().millisecondsSinceEpoch}-${result.length}',
        name        : props['name']?.toString() ?? '',
        shape       : shape,
        diameter    : diameter,
        memo        : memo,
        flowReversed: props['flowReversed'] as bool? ?? false,
        color       : props['color'] != null ? Color((props['color'] as num).toInt()) : Colors.blue,
        strokeWidth : (props['strokeWidth'] as num?)?.toDouble() ?? 7.5,
        showArrow   : props['showArrow'] as bool? ?? false,
        arrowSize   : (props['arrowSize'] as num?)?.toDouble() ?? 12.0,
        showHeadMark: props['showHeadMark'] as bool? ?? false,
        headMarkSize: (props['headMarkSize'] as num?)?.toDouble() ?? 10.0,
        points      : points,
        properties  : mergedProps,
      ));
    }
    return result;
  }

  /// GeoJSON features から勾配矢印スタンプ（Point型・type=='arrow_stamp'）を抽出。
  List<ArrowStamp> _parseArrowStampFeatures(List<dynamic> features) {
    final result = <ArrowStamp>[];
    for (final f in features) {
      final geometry = f['geometry'];
      if (geometry == null) continue;
      if (geometry['type'] != 'Point') continue;

      final props = f['properties'] as Map<String, dynamic>? ?? {};
      if (props['type']?.toString() != 'arrow_stamp') continue;

      final coords = geometry['coordinates'] as List<dynamic>;
      if (coords.length < 2) continue;

      result.add(ArrowStamp(
        id       : props['id']?.toString() ?? 'AR${DateTime.now().millisecondsSinceEpoch}',
        position : LatLng((coords[1] as num).toDouble(), (coords[0] as num).toDouble()),
        angleDeg : (props['angleDeg'] as num?)?.toDouble() ?? 0.0,
      ));
    }
    return result;
  }

  void _addParsedLayerWithStamps(
      List<Gutter> gutters, List<ArrowStamp> stamps, String name) {
    if (gutters.isEmpty) return;
    // 読み込み時点でデフォルトカテゴリ色分け（断面形状）を自動適用
    const defaultCategoryKey = 'shape';
    final defaultColors = {
      'BOX'  : Colors.orange,
      '円形'  : Colors.green,
      '開渠'  : Colors.blue,
      '未分類': Colors.grey,
    };
    setState(() {
      layers.add(GutterLayer(
        id            : DateTime.now().millisecondsSinceEpoch.toString(),
        name          : name,
        gutters       : gutters,
        stamps        : stamps,
        categoryKey   : defaultCategoryKey,
        categoryColors: defaultColors,
      ));
    });
    _showAllGutters();
  }

  // ================================================================
  // GeoJSON 読み込み（URL）→ Vercel Blob Private対応版
  // ================================================================

  Future<void> _loadFromUrl(String rawUrl, {bool isShared = false}) async {
    _showSnackBar(isShared ? '共有URLからデータを読み込み中...' : 'GeoJSONを読み込み中...');

    try {
      // Private Blob対応：cleanUrlを作らない（トークンが必要）
      final response = await http.get(Uri.parse(rawUrl));

      if (response.statusCode != 200) {
        throw Exception('HTTP ${response.statusCode}: ${response.body}');
      }

      final data     = jsonDecode(utf8.decode(response.bodyBytes)) as Map<String, dynamic>;
      final features = data['features'] as List<dynamic>? ?? [];

      if (isShared) {
        try {
          // shareId抽出（token部分は無視）
          final uri = Uri.parse(rawUrl);
          final shareId = uri.pathSegments.last
              .replaceAll('.geojson', '')
              .replaceAll('shared/', '');
          web.window.localStorage.setItem(_kShareIdKey, shareId);
        } catch (_) {}

        _sharedGeoJsonUrl = rawUrl;   // token付きのまま保存
        // リロード後も復元できるようlocalStorageにも保持
        try {
          web.window.localStorage.setItem(_kShareRawUrlKey, rawUrl);
        } catch (_) {}

        final hasLayerMeta = features.isNotEmpty &&
            ((features.first['properties'] as Map<String, dynamic>?)
                    ?.containsKey('layer') == true);

        if (hasLayerMeta) {
          // レイヤーごとにfeatureを振り分け（ラインとスタンプ両方）
          final layerMap      = <String, List<dynamic>>{};
          final layerNames    = <String, String>{};
          final stampLayerMap = <String, List<dynamic>>{};

          for (final f in features) {
            final props   = f['properties'] as Map<String, dynamic>? ?? {};
            final layerId = props['layerId']?.toString() ??
                props['layer']?.toString() ?? 'default';
            final layerName = props['layer']?.toString() ?? '共有データ';

            // ArrowStampはスタンプマップへ、それ以外はラインマップへ
            final isStamp = (f['geometry']?['type'] == 'Point') &&
                (props['type']?.toString() == 'arrow_stamp');
            if (isStamp) {
              stampLayerMap.putIfAbsent(layerId, () => []).add(f);
            } else {
              layerMap.putIfAbsent(layerId, () => []).add(f);
            }
            layerNames[layerId] = layerName;
          }

          if (layerMap.isEmpty) {
            _showSnackBar('有効なラインが見つかりませんでした');
            return;
          }

          // FeatureCollection トップレベルの layerStyles を取得
          final rawLayerStyles =
              (data['layerStyles'] as Map<String, dynamic>?) ?? {};

          int total = 0;
          setState(() {
            for (final entry in layerMap.entries) {
              final gutters = _parseGeoJsonFeatures(entry.value);
              if (gutters.isEmpty) continue;
              total += gutters.length;
              // 同レイヤーのArrowStampも復元
              final stamps = _parseArrowStampFeatures(
                stampLayerMap[entry.key] ?? [],
              );

              // layerStyles が保存されていればそれを復元、なければデフォルト
              final styleEntry =
                  rawLayerStyles[entry.key] as Map<String, dynamic>?;
              final String? categoryKey = styleEntry != null
                  ? styleEntry['categoryKey'] as String?
                  : 'shape';
              final Map<String, Color> categoryColors = styleEntry != null
                  ? ((styleEntry['categoryColors'] as Map<String, dynamic>?) ?? {})
                      .map((k, v) => MapEntry(k, Color(v as int)))
                  : {
                      'BOX'  : Colors.orange,
                      '円形'  : Colors.green,
                      '開渠'  : Colors.blue,
                      '未分類': Colors.grey,
                    };
              // ⑤ layerStyles から visible を復元（保存されていれば）
              final bool layerVisible = styleEntry != null
                  ? (styleEntry['visible'] as bool? ?? true)
                  : true;

              layers.add(GutterLayer(
                id            : entry.key,
                name          : layerNames[entry.key] ?? '共有データ',
                visible       : layerVisible,
                gutters       : gutters,
                stamps        : stamps,
                categoryKey   : categoryKey,
                categoryColors: categoryColors,
              ));
            }
          });

          if (layers.isNotEmpty) _showAllGutters();
          await _saveToLocalStorage();
          _showSnackBar('$total本の側溝を${layerMap.length}レイヤーで読み込みました');
          return;
        }
      }

      // layerMetaなしの場合
      final gutters = _parseGeoJsonFeatures(features);
      if (gutters.isEmpty) {
        _showSnackBar('有効なラインが見つかりませんでした');
        return;
      }

      final label = isShared
          ? '共有データ ${DateTime.now().toIso8601String().substring(0, 10)}'
          : 'URL読み込み ${layers.length + 1}';

      // ArrowStampも復元
      final stamps = _parseArrowStampFeatures(features);
      _addParsedLayerWithStamps(gutters, stamps, label);
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
        allowMultiple    : true,
      );
      if (result == null || result.files.isEmpty) return;

      int totalAdded = 0;
      int layerAdded = 0;

      for (final file in result.files) {
        try {
          final data    = jsonDecode(utf8.decode(file.bytes!)) as Map<String, dynamic>;
          final features = data['features'] as List<dynamic>? ?? [];
          final gutters = _parseGeoJsonFeatures(features);
          final stamps  = _parseArrowStampFeatures(features);

          if (gutters.isEmpty) continue;

          final layerName = file.name.replaceAll(
              RegExp(r'\.(geojson|json)$', caseSensitive: false), '');
          _addParsedLayerWithStamps(gutters, stamps, layerName);
          totalAdded += gutters.length;
          layerAdded++;
        } catch (e) {
          _showSnackBar('${file.name} の読み込みエラー: $e');
        }
      }

      if (layerAdded == 0) {
        _showSnackBar('有効なラインがありませんでした');
        return;
      }

      _showSnackBar('$totalAdded 件を $layerAdded レイヤーに追加しました');

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

  /// 共通アップロード処理。[forceNewId] が true なら必ず新しいIDを発行する。
  Future<void> _uploadAllLayers({bool forceNewId = false}) async {
    if (layers.isEmpty) {
      _showSnackBar('保存するデータがありません。先にGeoJSONを読み込んでください');
      return;
    }

    try {
      // shareId の決定
      String shareId;
      if (forceNewId) {
        // 新規URL発行：必ず新しいIDを生成（既存データは別URLのまま残る）
        shareId = DateTime.now().millisecondsSinceEpoch.toString();
      } else if (_sharedGeoJsonUrl != null) {
        // 更新：現在の共有URLのIDを再利用
        shareId = Uri.parse(_sharedGeoJsonUrl!).pathSegments.last
            .replaceAll('.geojson', '')
            .replaceAll('shared/', '');
      } else {
        try {
          shareId = web.window.localStorage.getItem(_kShareIdKey) ?? '';
          if (shareId.isEmpty) {
            shareId = DateTime.now().millisecondsSinceEpoch.toString();
          }
        } catch (_) {
          shareId = DateTime.now().millisecondsSinceEpoch.toString();
        }
      }

      final features = _buildFeatureList(withLayerMeta: true);
      // レイヤーのスタイル設定（categoryKey・categoryColors）を別途保存
      // FeatureCollection のトップレベルに埋め込むことで読み込み時に復元できる
      final layerStyles = {
        for (final layer in layers)
          layer.id: {
            'categoryKey'   : layer.categoryKey,
            'categoryColors': layer.categoryColors.map(
              (k, v) => MapEntry(k, v.toARGB32()),
            ),
            'visible': layer.visible,
          },
      };
      final geojson = {
        'type'         : 'FeatureCollection',
        'features'     : features,
        'layerStyles'  : layerStyles,
        'exported_at'  : DateTime.now().toIso8601String(),
        'layers_count' : layers.length,
        'gutters_count': features.length,
      };

      // Blob用APIにアップロード
      final apiUrl = '${web.window.location.origin}/api/uploadToBlob';

      final response = await http.post(
        Uri.parse(apiUrl),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'shareId': shareId,
          'geojson': geojson,
        }),
      );

      if (response.statusCode != 200) {
        throw Exception('HTTP ${response.statusCode}: ${response.body}');
      }

      final data = jsonDecode(response.body) as Map<String, dynamic>;
      final rawUrl = data['rawUrl'] as String;
      _sharedGeoJsonUrl = rawUrl;

      // localStorageにも保存（リロード後もアップロード先URLを維持するため）
      try {
        web.window.localStorage.setItem(_kShareIdKey, data['shareId'] as String? ?? shareId);
        web.window.localStorage.setItem(_kShareRawUrlKey, rawUrl);
      } catch (_) {}

      final shareUrl = data['shareUrl'] as String? ??
          '${web.window.location.origin}/?geojson=${Uri.encodeComponent(rawUrl)}';

      try {
        await Clipboard.setData(ClipboardData(text: shareUrl));
      } catch (_) {}

      if (!mounted) return;

      _showShareDialog(shareUrl, isNew: forceNewId);
      _showSnackBar(forceNewId
          ? '✅ 新しい共有リンクを発行しました（${features.length}本）'
          : '✅ クラウドに保存しました（${features.length}本）');

    } catch (e) {
      _showSnackBar('クラウド保存に失敗しました: $e');
      debugPrint('Upload error: $e');
    }
  }


  // ダイアログ（新規URL発行かアップロード共有かで表示を切り替え）
  void _showShareDialog(String shareUrl, {bool isNew = false}) {
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        title: Text(isNew ? '新しい共有リンクを発行しました' : 'クラウド保存が完了しました'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              isNew
                  ? '✅ 新しい共有リンクを発行しました！'
                  : '✅ 最新データをクラウドに保存しました！',
              style: const TextStyle(color: Colors.green, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            Text(
              isNew
                  ? 'このリンクを相手に送ると、今の地図データをそのまま開けます。\n以前の共有リンクとは別のURLです。'
                  : '以前に共有したリンクを開き直すと、今回保存した最新データが表示されます。',
              style: const TextStyle(fontSize: 12, color: Colors.black87),
            ),
            const SizedBox(height: 12),
            const Text('📋 リンクはクリップボードにコピー済みです。'),
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: Colors.grey.shade100,
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
            icon: const Icon(Icons.copy),
            label: const Text('もう一度コピー'),
            onPressed: () => Clipboard.setData(ClipboardData(text: shareUrl)),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('閉じる'),
          ),
        ],
      ),
    );
  }

  // ================================================================
  // Feature リスト生成（エクスポート・アップロード共用）
  // ================================================================

  List<Map<String, dynamic>> _buildFeatureList({required bool withLayerMeta}) {
    final lineFeatures = [
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
                'layer'          : layer.name,
                'layerId'        : layer.id,
                'layerVisible'   : layer.visible,
                'shape'          : g.shape,
                'diameter'       : g.diameter,
                'memo'           : g.memo,
                'flowReversed'   : g.flowReversed,
                'color'          : g.color.toARGB32(),
                'strokeWidth'    : g.strokeWidth,
                'showArrow'      : g.showArrow,
                'arrowSize'      : g.arrowSize,
                'showHeadMark'   : g.showHeadMark,
                'headMarkSize'   : g.headMarkSize,

              },
            },
          },
    ];

     // 矢印スタンプ（Pointデータ）を追加
    final stampFeatures = [
      for (final layer in layers)
        if (withLayerMeta || layer.visible)  // 共有時は全レイヤー含む
          for (final s in layer.stamps)
            s.toGeoJsonFeature(
              layerName: withLayerMeta ? layer.name : '',
              layerId  : withLayerMeta ? layer.id   : '',
            ),
    ];

    return [...lineFeatures, ...stampFeatures];
  }

  // ================================================================
  // モード切り替え
  // ================================================================

  void _toggleAddMode() => setState(() {
    isAddingNew = !isAddingNew;

    if (isAddingNew) {
      // 他のモードをすべてオフ
      isCutting = false;
      isDeleting = false;
      isStamp2Pt = false;
      _stamp2PtFirst = null;
      newPoints.clear();
    } else {
      // モード終了時もクリア
      newPoints.clear();
    }
  });

  void _toggleCutMode() => setState(() {
    isCutting      = !isCutting;
    isAddingNew    = false;
    isDeleting     = false;
    isStamp2Pt     = false;
    _stamp2PtFirst = null;
  });

  void _toggleDeleteMode() => setState(() {
    isDeleting = !isDeleting;
    if (isDeleting) {
      isAddingNew = false;
      isCutting = false;
      isStamp2Pt = false;
      _stamp2PtFirst = null;
    }
  });

  void _toggleStamp2PtMode() {
    setState(() {
      isStamp2Pt = !isStamp2Pt;

      if (isStamp2Pt) {
        // 他のモードをすべてオフ
        isAddingNew = false;
        isCutting = false;
        isDeleting = false;
        _stamp2PtFirst = null;
      }
    });
  }
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

    if (isStamp2Pt) {
      _handleStamp2PtTap(point);
      return;
    }

    if (isDeleting) {
      final nearest = _findNearestGutterInLayer(point, layer);
      if (nearest != null) {
        _saveStateForUndo();
        final targetId = nearest.id;
        setState(() {
          final idx = selectedLayerIndex ?? 0;
          layers[idx].gutters.removeWhere((g) => g.id == targetId);
        });
        _saveToLocalStorage();
        _showSnackBar('側溝を削除しました');
      }
      return;
    }

    if (isAddingNew) {
      final snapped = _trySnap(point);
      if (snapped != null) {
        setState(() => newPoints.add(snapped));
      } else {
        setState(() => newPoints.add(point));
      }
      return;
    }

    if (isCutting) {
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

    final g   = layer.gutters[bestIdx];
    final pts = g.points;

    // 折れ点スナップ：中間点が近ければ射影点の代わりに折れ点で切断
    LatLng cutPoint = bestProj;
    int?   snapVertexIdx;
    if (_snapEnabled) {
      double bestVertDist = _kSnapRadiusM;
      for (int k = 1; k < pts.length - 1; k++) { // 両端除く中間点のみ
        final d = _distance.distance(tapPoint, pts[k]);
        if (d < bestVertDist) {
          bestVertDist = d;
          snapVertexIdx = k;
        }
      }
      if (snapVertexIdx != null) {
        cutPoint = pts[snapVertexIdx];
      }
    }

    // 切断前にデータをコピーしておく（setState内でlayerを引き直すため）
    final layerIdx   = selectedLayerIndex ?? 0;
    final gId        = g.id;
    final gName      = g.name;
    final gShape     = g.shape;
    final gDiameter  = g.diameter;
    final gMemo      = g.memo;
    final gReversed  = g.flowReversed;
    final gColor     = g.color;
    final gArrow     = g.showArrow;
    final gArrowSize = g.arrowSize;
    final gStroke    = g.strokeWidth;
    final gHeadMark  = g.showHeadMark;
    final gHeadSize  = g.headMarkSize;
    final gProps     = Map<String, dynamic>.from(g.properties);
    final List<LatLng> ptsA;
    final List<LatLng> ptsB;
    if (snapVertexIdx != null) {
      ptsA = [...pts.sublist(0, snapVertexIdx + 1)];
      ptsB = [...pts.sublist(snapVertexIdx)];
    } else {
      ptsA = [...pts.sublist(0, bestSeg + 1), cutPoint];
      ptsB = [cutPoint, ...pts.sublist(bestSeg + 1)];
    }

    _saveStateForUndo();
    setState(() {
      final lyr = layers[layerIdx];
      lyr.gutters.removeAt(bestIdx);
      lyr.gutters.add(Gutter(
        id             : '$gId-A',
        name           : '$gName-A',
        shape          : gShape,
        diameter       : gDiameter,
        memo           : gMemo,
        flowReversed   : gReversed,
        color          : gColor,
        showArrow      : gArrow,
        arrowSize      : gArrowSize,
        strokeWidth    : gStroke,
        showHeadMark   : gHeadMark,
        headMarkSize   : gHeadSize,
        properties     : Map<String, dynamic>.from(gProps),
        points         : ptsA,
      ));
      lyr.gutters.add(Gutter(
        id             : '$gId-B',
        name           : '$gName-B',
        shape          : gShape,
        diameter       : gDiameter,
        memo           : gMemo,
        flowReversed   : gReversed,
        color          : gColor,
        showArrow      : gArrow,
        arrowSize      : gArrowSize,
        strokeWidth    : gStroke,
        showHeadMark   : gHeadMark,
        headMarkSize   : gHeadSize,
        properties     : Map<String, dynamic>.from(gProps),
        points         : ptsB,
      ));
    });

    _saveToLocalStorage();
    final snapMsg = snapVertexIdx != null ? '（折れ点スナップ）' : '';
    _showSnackBar('切断完了 (${bestDist.toStringAsFixed(1)}m) $snapMsg');
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

  /// 全レイヤーの端点・折れ点から最近傍を探してスナップ。
  /// _kSnapRadiusM 以内に点があればその座標を返し、なければ null。
  LatLng? _trySnap(LatLng tap) {
    if (!_snapEnabled) return null;
    double  best    = _kSnapRadiusM;
    LatLng? snapped;
    for (final layer in layers) {
      for (final g in layer.gutters) {
        for (final pt in g.points) {
          final d = _distance.distance(tap, pt);
          if (d < best) {
            best    = d;
            snapped = pt;
          }
        }
      }
    }
    return snapped;
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

    final ctrl = TextEditingController(text: '');
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
                // isAddingNew = false; // モードを維持して続けて追加できるようにする
              });
              _saveToLocalStorage();
              _showSnackBar('「${layer.name}」に追加しました。続けてタップで次の路線を追加できます。');
              Navigator.pop(ctx);
            },
            child: const Text('保存'),
          ),
        ],
      ),
    );
  }

  // ================================================================
  // 2点指定スタンプ（方向を自動計算）
  // ================================================================

  void _handleStamp2PtTap(LatLng point) {
    if (_stamp2PtFirst == null) {
      setState(() => _stamp2PtFirst = point);
      _showSnackBar('① 高い側（始点）をタップしました\n② 低い側（終点）をタップ');
    } else {
      _createFlowArrow(_stamp2PtFirst!, point);
      setState(() {
        _stamp2PtFirst = null;
        // isStamp2Pt = false; // モードを維持して続けて追加できるようにする
      });
    }
  }

  void _createFlowArrow(LatLng start, LatLng end) {
    if (_currentLayer == null) {
      _showSnackBar('レイヤーが選択されていません');
      return;
    }

    // start（1点目）が根本、end（2点目）が先端になるよう方向を計算する。
    // atan2(東成分, 北成分) で北=0°・時計回りの方位角を求める。
    final dx = end.longitude - start.longitude;  // 東方向成分（正=東）
    final dy = end.latitude  - start.latitude;   // 北方向成分（正=北）

    double angleDeg = math.atan2(dx, dy) * 180 / math.pi;
    if (angleDeg < 0) angleDeg += 360;

    // 中間点に配置
    final midPoint = LatLng(
      (start.latitude + end.latitude) / 2,
      (start.longitude + end.longitude) / 2,
    );

    final stamp = ArrowStamp(
      id: 'AR${DateTime.now().millisecondsSinceEpoch}',
      position: midPoint,
      angleDeg: angleDeg,
    );

    // 矢印1本追加ごとにUndo状態を記録
    _saveStateForUndo();

    setState(() {
      _currentLayer!.stamps.add(stamp);
    });

    _saveToLocalStorage();
    _showSnackBar('勾配矢印を追加しました');
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
                        onTap : () => setS(() { g.color = c; g.properties['color'] = c.toARGB32(); }),
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
                                // カテゴリ色分けがpropertiesを参照するため
                                // フィールドと同期して書き込む
                                g.properties['shape']    = g.shape;
                                g.properties['diameter'] = g.diameter;
                                g.properties['memo']     = g.memo;
                                g.properties['name']     = g.name;
                              });
                              await _saveToLocalStorage();
                              if (!ctx.mounted) return;
                              Navigator.pop(ctx);
                              if (!mounted) return;
                              // 🍋 イースターエッグ：「檸檬爆弾」で梶井基次郎『檸檬』を開く
                              if (g.memo.contains('檸檬爆弾')) {
                                web.window.open(
                                  'https://www.aozora.gr.jp/cards/000074/files/424_19826.html',
                                  '_blank',
                                );
                              }
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
    // 最大表示件数：5件。それ以上はスクロール
    const maxItems     = 5;
    const itemHeight   = 48.0;

    return Autocomplete<String>(
      initialValue: TextEditingValue(text: initial == '---' ? '' : initial),
      optionsBuilder: (textEditingValue) {
        final input = textEditingValue.text;
        if (input.isEmpty) return options;
        return options.where((o) => filter(o, input));
      },
      displayStringForOption: display,
      fieldViewBuilder: (context, textCtrl, focusNode, onFieldSubmitted) {
        // 外部 ctrl と同期
        textCtrl.text = ctrl.text == '---' ? '' : ctrl.text;
        textCtrl.addListener(() => ctrl.text = textCtrl.text.isEmpty ? '---' : textCtrl.text);
        return TextField(
          controller : textCtrl,
          focusNode  : focusNode,
          decoration : InputDecoration(
            labelText: label,
            hintText : hint,
            border   : const OutlineInputBorder(),
            isDense  : true,
          ),
          onSubmitted: (_) => onFieldSubmitted(),
        );
      },
      optionsViewBuilder: (context, onSelected, options) {
        final list = options.toList();
        final viewHeight = math.min(list.length, maxItems) * itemHeight;
        return Align(
          alignment: Alignment.topLeft,
          child: Material(
            elevation: 4,
            borderRadius: BorderRadius.circular(8),
            child: SizedBox(
              width : 300,  // フィールド幅に合わせて適宜調整
              height: viewHeight,
              child : ListView.builder(
                padding    : EdgeInsets.zero,
                itemCount  : list.length,
                itemExtent : itemHeight,
                itemBuilder: (context, index) {
                  final option = list[index];
                  return InkWell(
                    onTap: () => onSelected(option),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                      child  : Text(display(option)),
                    ),
                  );
                },
              ),
            ),
          ),
        );
      },
      onSelected: (value) => ctrl.text = value,
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
    final ctrl = TextEditingController();
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title  : const Text('新規レイヤー作成'),
        content: TextField(
          controller : ctrl,
          autofocus  : true,
          decoration : const InputDecoration(
            labelText: 'レイヤー名',
            hintText : '例）区域A・幹線など',
            border   : OutlineInputBorder(),
            isDense  : true,
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child    : const Text('キャンセル'),
          ),
          FilledButton(
            onPressed: () {
              final name = ctrl.text.trim();
              if (name.isEmpty) return; // 空欄は受け付けない
              setState(() {
                layers.add(GutterLayer(
                  id            : DateTime.now().millisecondsSinceEpoch.toString(),
                  name          : name,
                  gutters       : [],
                  categoryKey   : 'shape',
                  categoryColors: {
                    'BOX'  : Colors.orange,
                    '円形'  : Colors.green,
                    '開渠'  : Colors.blue,
                    '未分類': Colors.grey,
                  },
                ));
              });
              _saveToLocalStorage();
              Navigator.pop(ctx);          // ダイアログを閉じる
              Navigator.of(context).maybePop(); // ドロワーを閉じる（開いていれば）
            },
            child: const Text('作成'),
          ),
        ],
      ),
    );
  }

  // ================================================================
  // カテゴリ色分け
  // ================================================================

  /// 断面（shape）の入力有無でデフォルト色を返すヘルパー
  /// shape が '---' / 空 → 未入力 → グレー
  /// shape が入力済み   → 種別ごとの固定色
  Color _getGutterColor(Gutter g, GutterLayer layer) {
    // カテゴリ色分けが有効な場合はそちらを優先
    if (layer.categoryKey != null && layer.categoryColors.isNotEmpty) {
      final raw   = g.properties[layer.categoryKey!];
      final value = _normalizeShapeValue(raw?.toString().trim() ?? '');
      return layer.categoryColors[value] ??
             layer.categoryColors['未分類'] ??
             Colors.grey;
    }
    // 明示的に色変更されていない外部GeoJSONデータは断面形状で自動色分け
    final hasExplicitColor = g.properties.containsKey('color');
    if (!hasExplicitColor && g.color.toARGB32() == Colors.blue.toARGB32()) {
      return _shapeNameToColor(_normalizeShapeValue(g.shape.trim()));
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

  List<String> _getAllPropertyKeys(GutterLayer layer) {
    // カテゴリ色分けに意味のないキーを除外
    const excludeKeys = {
      'color', 'strokeWidth', 'showArrow', 'arrowSize',
      'showHeadMark', 'headMarkSize', 'flowReversed',
      'layerId', 'layerVisible',
    };
    return ({
      for (final g in layer.gutters) ...g.properties.keys,
    }
      .where((k) => !excludeKeys.contains(k))
      .toList()
      ..sort((a, b) {
        // 日本語ラベルがあるキーを上位に
        final aHas = _kPropKeyLabels.containsKey(a) ? 0 : 1;
        final bHas = _kPropKeyLabels.containsKey(b) ? 0 : 1;
        if (aHas != bHas) return aHas - bHas;
        return a.compareTo(b);
      }));
  }

  // ----------------------------------------------------------------
  // カテゴリ色分けユーティリティ
  // ----------------------------------------------------------------

  /// shape 属性のデフォルトカテゴリ（値が未設定でも常に表示する固定4項目）。
  static const _kShapeCategories = ['BOX', '円形', '未分類', '開渠'];

  /// shape値 → 固定色マッピング（_defaultShapeColor と対応）
  static Color _shapeNameToColor(String shape) {
    switch (shape) {
      case '開渠'  : return Colors.blue;
      case 'BOX'   : return Colors.orange;
      case '円形'  : return Colors.green;
      case '未分類': return Colors.grey.shade400;
      default      : return Colors.purple;
    }
  }

  /// [key] 属性の値一覧を返す。
  /// - '---' / 空文字 → '未分類' に正規化
  /// - shape キーは _kShapeCategories を固定ベースとして使い、
  ///   データに存在する追加値も末尾に補完する
  /// - 'layer' キーはレイヤー順、それ以外はアルファベット順
  List<String> _getUniqueValues(GutterLayer layer, String? key) {
    if (key == null) return [];

    // データから収集した値（正規化済み）
    final fromData = {
      for (final g in layer.gutters)
        _normalizeShapeValue(g.properties[key]?.toString().trim() ?? ''),
    };

    // shape キーは固定4項目をベースに、データ独自の追加値を末尾補完
    if (_isShapeKey(key)) {
      final extras = fromData.difference(_kShapeCategories.toSet())
        ..remove('未分類');
      final extraList = extras.toList()..sort();
      return [..._kShapeCategories, ...extraList];
    }

    final values = fromData.toList();
    if (key == 'layer') {
      // レイヤー登録順にソート
      final order = {for (int i = 0; i < layers.length; i++) layers[i].name: i};
      values.sort((a, b) {
        final ia = order[a] ?? layers.length;
        final ib = order[b] ?? layers.length;
        return ia != ib ? ia.compareTo(ib) : a.compareTo(b);
      });
    } else {
      values.sort();
    }
    return values;
  }

  /// shape 関連キーかどうか
  static bool _isShapeKey(String key) => key == 'shape' || key == '断面形状';

  /// '---' / 空文字 → '未分類' に正規化
  static String _normalizeShapeValue(String v) =>
      (v.isEmpty || v == '---') ? '未分類' : v;

  /// [key] 属性のカテゴリ → 初期色マッピングを生成する。
  /// shape キーは _kShapeCategories 全項目の固定色を返すため、
  /// データに値が1件も無くても4カテゴリが揃う。
  Map<String, Color> _generateCategoryColors(GutterLayer layer, String key) {
    final values = _getUniqueValues(layer, key);
    if (_isShapeKey(key)) {
      return {for (final v in values) v: _shapeNameToColor(v)};
    }
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
                      ..._getAllPropertyKeys(layer).map((k) {
                        final label = _kPropKeyLabels[k] ?? k; // 日本語ラベルがあれば使う
                        return DropdownMenuItem(
                          value: k,
                          child: Text(label),
                        );
                      }),
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
                  // '---' や空キーを '未分類' に正規化してから保存
                  final normalized = <String, Color>{};
                  tempColors.forEach((k, v) {
                    final nk = (k.trim().isEmpty || k == '---') ? '未分類' : k;
                    normalized[nk] = v;
                  });
                  setState(() {
                    layers[layerIndex].categoryKey    = selectedKey;
                    layers[layerIndex].categoryColors = normalized;
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
  // 一括スタイル変更（レイヤー内の全路線）
  // ================================================================

  void _showBulkStyleDialog(int layerIndex) {
    final layer = layers[layerIndex];
    if (layer.gutters.isEmpty) {
      _showSnackBar('このレイヤーに路線がありません');
      return;
    }

    // 現在値の代表値（最初の路線から取得）
    double bulkStroke    = layer.gutters.first.strokeWidth;
    bool   bulkShowArrow = layer.gutters.first.showArrow;
    double bulkArrowSize = layer.gutters.first.arrowSize;
    bool   bulkShowHead  = layer.gutters.first.showHeadMark;
    double bulkHeadSize  = layer.gutters.first.headMarkSize;
    // 一括色：null = 変更しない
    Color? bulkColor;

    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (context, setS) => AlertDialog(
          title: Text('一括スタイル変更\n「${layer.name}」', style: const TextStyle(fontSize: 15)),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // ── 一括色変更（カテゴリ無効時に有効）────────────────
                const Text('一括色変更',
                    style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
                const SizedBox(height: 4),
                if (layer.categoryKey != null)
                  Container(
                    padding   : const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                    decoration: BoxDecoration(
                      color       : Colors.amber.shade50,
                      borderRadius: BorderRadius.circular(8),
                      border      : Border.all(color: Colors.amber.shade300),
                    ),
                    child: const Text(
                      'カテゴリ色分けが有効のため、個別色は表示に影響しません。\n'
                      '色変更を反映するにはカテゴリ色分けを無効にしてください。',
                      style: TextStyle(fontSize: 11, color: Colors.brown),
                    ),
                  ),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    // 「変更しない」選択肢
                    GestureDetector(
                      onTap: () => setS(() => bulkColor = null),
                      child: Container(
                        width : 40,
                        height: 40,
                        decoration: BoxDecoration(
                          color : Colors.grey.shade200,
                          shape : BoxShape.circle,
                          border: Border.all(
                            color: bulkColor == null ? Colors.black : Colors.transparent,
                            width: 3,
                          ),
                        ),
                        child: const Icon(Icons.block, size: 18, color: Colors.grey),
                      ),
                    ),
                    ..._kColorPalette.map((c) => GestureDetector(
                      onTap : () => setS(() => bulkColor = c),
                      child : Container(
                        width : 40,
                        height: 40,
                        decoration: BoxDecoration(
                          color : c,
                          shape : BoxShape.circle,
                          border: Border.all(
                            color: bulkColor?.toARGB32() == c.toARGB32()
                                ? Colors.black
                                : Colors.transparent,
                            width: 3,
                          ),
                        ),
                      ),
                    )),
                  ],
                ),
                const Divider(height: 20),

                // ── 線の太さ ──────────────────────────────────────
                const Text('線の太さ', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
                Row(
                  children: [
                    Expanded(
                      child: Slider(
                        value    : bulkStroke,
                        min      : 3.0,
                        max      : 15.0,
                        divisions: 24,
                        label    : bulkStroke.toStringAsFixed(1),
                        onChanged: (v) => setS(() => bulkStroke = v),
                      ),
                    ),
                    SizedBox(
                      width: 32,
                      child: Text(bulkStroke.toStringAsFixed(1),
                          style: const TextStyle(fontSize: 12)),
                    ),
                  ],
                ),
                const Divider(height: 20),

                // ── 流向矢印 ─────────────────────────────────────
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    const Text('流向矢印（ライン末端）',
                        style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
                    Switch.adaptive(
                        value: bulkShowArrow, onChanged: (v) => setS(() => bulkShowArrow = v)),
                  ],
                ),
                if (bulkShowArrow)
                  Row(
                    children: [
                      const Text('矢印サイズ', style: TextStyle(fontSize: 12)),
                      Expanded(
                        child: Slider(
                          value    : bulkArrowSize,
                          min      : 5.0,
                          max      : 20.0,
                          divisions: 30,
                          label    : bulkArrowSize.toStringAsFixed(1),
                          onChanged: (v) => setS(() => bulkArrowSize = v),
                        ),
                      ),
                      SizedBox(
                        width: 32,
                        child: Text(bulkArrowSize.toStringAsFixed(1),
                            style: const TextStyle(fontSize: 12)),
                      ),
                    ],
                  ),
                const Divider(height: 20),

                // ── 最上流マーク ──────────────────────────────────
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    const Text('最上流マーク',
                        style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
                    Switch.adaptive(
                        value: bulkShowHead, onChanged: (v) => setS(() => bulkShowHead = v)),
                  ],
                ),
                if (bulkShowHead)
                  Row(
                    children: [
                      const Text('マークサイズ', style: TextStyle(fontSize: 12)),
                      Expanded(
                        child: Slider(
                          value    : bulkHeadSize,
                          min      : 5.0,
                          max      : 20.0,
                          divisions: 30,
                          label    : bulkHeadSize.toStringAsFixed(1),
                          onChanged: (v) => setS(() => bulkHeadSize = v),
                        ),
                      ),
                      SizedBox(
                        width: 32,
                        child: Text(bulkHeadSize.toStringAsFixed(1),
                            style: const TextStyle(fontSize: 12)),
                      ),
                    ],
                  ),
              ],
            ),
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
                  final lyr = layers[layerIndex];
                  for (final g in lyr.gutters) {
                    if (bulkColor != null) { g.color = bulkColor!; g.properties['color'] = bulkColor!.toARGB32(); }
                    g.strokeWidth  = bulkStroke;
                    g.showArrow    = bulkShowArrow;
                    g.arrowSize    = bulkArrowSize;
                    g.showHeadMark = bulkShowHead;
                    g.headMarkSize = bulkHeadSize;
                  }
                  if (bulkColor != null) {
                    lyr.categoryKey    = null;
                    lyr.categoryColors = {};
                  }
                });
                _saveToLocalStorage();
                Navigator.pop(ctx);
                _showSnackBar('${layers[layerIndex].gutters.length}本に一括適用しました');
              },
              child: const Text('一括適用'),
            ),
          ],
        ),
      ),
    );
  }

  // ================================================================
  // 流向矢印（＞型ポリライン）
  // ================================================================

  /// 流向矢印ポリラインを返す。
  /// [shadow] = true のとき、視認性向上用の白いアウトライン用ポリラインを返す。
  /// 白アウトラインは矢印本体より2px太くし、本体の下レイヤーに描くことで
  /// 路線色と被っても読めるようにする（縁取りとは異なり控えめな効果）。
  List<Polyline> _createFlowArrowPolylines({bool shadow = false}) {
    final result = <Polyline>[];
    for (final layer in layers) {
      if (!layer.visible) continue;
      for (final g in layer.gutters) {
        if (!g.showArrow || g.points.length < 2) continue;
        final color   = _getGutterColor(g, layer);
        final baseW   = math.max(1.5, _scaledStrokeWidth(g.strokeWidth * 0.6));
        final strokeW = shadow ? baseW + 2.0 : baseW;
        final segs = _arrowheadPolylinePoints(
          g.points[g.points.length - 2],
          g.points.last,
          sizeMeters: g.arrowSize,
        );
        result.add(Polyline(
          points     : segs,
          color      : shadow
              ? Colors.white.withValues(alpha: 0.75)
              : color,
          strokeWidth: strokeW,
          strokeCap  : StrokeCap.round,
          strokeJoin : StrokeJoin.round,
        ));
      }
    }
    return result;
  }

  /// 矢印先端の「＞」形状を表す3点リスト [左翼端, 先端, 右翼端] を返す。
  /// 翼の開き角は従来ポリゴンと同じ 15° × 2 = 30°（halfWidth は tan15° で計算）。
  List<LatLng> _arrowheadPolylinePoints(LatLng from, LatLng to,
      {double sizeMeters = 12.0}) {
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

    // 左翼端 → 先端 → 右翼端 の順（Polyline の折れ線で ＞ を表現）
    return [
      LatLng(to.latitude  + (by + vy * halfWidth) / mPerDegLat,
             to.longitude + (bx + vx * halfWidth) / mPerDegLon),
      to,
      LatLng(to.latitude  + (by - vy * halfWidth) / mPerDegLat,
             to.longitude + (bx - vx * halfWidth) / mPerDegLon),
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
      strokeWidth: math.max(0.8, _scaledStrokeWidth(g.strokeWidth * 0.22)),
    );
  }

  // ================================================================
  // ユーティリティ
  // ================================================================

  /// ズームレベルに応じて線幅をスケーリングする。
  /// 基準ズーム17 で g.strokeWidth の 2/3 が使われ、
  /// 1段ズームアウトするごとに約29%細くなる（2^0.5 ≒ 1.41 倍ステップ）。
  static const _kStrokeBaseScale = 2.0 / 3.0; // 初期表示の太さ補正（元の2/3）
  double _scaledStrokeWidth(double base) {
    const baseZoom = 17.0;
    final scale = math.pow(2.0, (_currentZoom - baseZoom) * 0.5).toDouble();
    return (base * _kStrokeBaseScale * scale).clamp(0.8, base * 6);
  }

  void _showSnackBar(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content        : Text(message),
        behavior       : SnackBarBehavior.floating,
        duration       : const Duration(seconds: 2),
        margin         : const EdgeInsets.fromLTRB(16, 60, 16, 0),
        // 上部に表示するため SnackBarBehavior.floating + 上マージン設定
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
                  : isStamp2Pt
                      ? '勾配矢印モード（${_stamp2PtFirst == null ? "1点目をタップ" : "2点目をタップ"}）'
                      : '側溝踏査マップ',
      style: const TextStyle(fontSize: 15, fontWeight: FontWeight.bold),
    ),
    bottom: (!isAddingNew && !isCutting && !isDeleting && !isStamp2Pt)
        ? PreferredSize(
            preferredSize: const Size.fromHeight(20),
            child: Padding(
              padding: const EdgeInsets.only(bottom: 5),
              child: Text(
                _currentLayer != null
                    ? '編集中レイヤー：${_currentLayer!.name}'
                    : 'レイヤー未選択',
                style: const TextStyle(color: Colors.white70, fontSize: 12),
              ),
            ),
          )
        : null,
    backgroundColor: isAddingNew
        ? Colors.orange
        : isCutting
            ? Colors.purple
            : isDeleting
                ? Colors.red
                : isStamp2Pt
                    ? Colors.teal
                    : Colors.blue,
    foregroundColor: Colors.white,
    actions: [
      // ファイルを開く
      IconButton(
        icon    : const Icon(Icons.folder_open),
        tooltip : 'ファイルを開く（GeoJSON）',
        onPressed: _loadGeoJSON,
      ),
      // ファイルに書き出す
      IconButton(
        icon    : const Icon(Icons.save_alt),
        tooltip : 'ファイルに書き出す（GeoJSON）',
        onPressed: _exportGeoJSON,
      ),
      // 新規共有リンクを発行
      IconButton(
        icon    : const Icon(Icons.share),
        tooltip : '新しい共有リンクを発行',
        onPressed: () => _uploadAllLayers(forceNewId: true),
      ),
      // URLを更新
      IconButton(
        icon    : const Icon(Icons.cloud_sync),
        tooltip : 'URLを更新（クラウド保存）',
        onPressed: _uploadAllLayers,
      ),
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
        itemBuilder: (_) => _kTileLabels.entries
            .map((e) => PopupMenuItem(
                  value: e.key,
                  child: Row(
                    children: [
                      Icon(
                        e.key == 'osm'
                            ? Icons.map
                            : e.key == 'google_hybrid'
                                ? Icons.map_outlined
                                : Icons.satellite_alt,
                        size: 18,
                        color: currentTile == e.key
                            ? Theme.of(context).colorScheme.primary
                            : null,
                      ),
                      const SizedBox(width: 8),
                      Text(
                        e.value,
                        style: TextStyle(
                          fontWeight: currentTile == e.key
                              ? FontWeight.bold
                              : FontWeight.normal,
                        ),
                      ),
                    ],
                  ),
                ))
            .toList(),
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
      if (isAddingNew || isCutting || isDeleting || isStamp2Pt)
        Positioned(
          top  : 0,
          left : 0,
          right: 0,
          child: Container(
            color: (isAddingNew
                    ? Colors.orange
                    : isCutting
                        ? Colors.purple
                        : isDeleting
                            ? Colors.red
                            : Colors.teal)
                .withValues(alpha: 0.85),
            padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 12),
            child: Text(
              isAddingNew
                  ? '地図をタップして点を追加 → ✔で保存'
                  : isCutting
                      ? 'ラインをタップして切断'
                      : isDeleting
                          ? '削除したいラインをタップ'
                          : isStamp2Pt
                              ? (_stamp2PtFirst == null
                                  ? '① 始点（高い側）をタップ'
                                  : '② 終点（低い側）をタップ → 角度を自動計算します')
                              : '',
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
      // 左下：選択中レイヤーバッジ（常時表示）
      Positioned(
        left  : 12,
        bottom: 24,
        child : _buildLayerBadge(),
      ),
    ],
  );

  Widget _buildMap() => FlutterMap(
    mapController: _mapController,
    options      : MapOptions(
      initialCenter: const LatLng(36.555, 139.882),
      initialZoom  : 17.0,
      maxZoom      : 22.0,   // ← マップ自体のズーム上限を22に設定
      onTap        : _addPoint,
      onMapEvent   : (event) {
        final zoom = event.camera.zoom;
        if ((zoom - _currentZoom).abs() > 0.01) {
          setState(() => _currentZoom = zoom);
        }
      },
    ),
    children: [
      TileLayer(
        urlTemplate        : _kTileUrls[currentTile] ?? _kTileUrls['osm']!,
        userAgentPackageName: 'com.example.sideGutter_map',
        // タイル種別ごとのネイティブズーム上限を設定。
        // これを超えた場合は上限タイルを拡大表示するため画面が白くならない。
        maxNativeZoom: _kTileMaxNativeZoom[currentTile] ?? 19,
        maxZoom      : 22,
      ),
      ...layers.where((l) => l.visible).map(
        (layer) => PolylineLayer(
          polylines: layer.gutters.map((g) => Polyline(
            points           : g.points,
            color            : _getGutterColor(g, layer),
            strokeWidth      : _scaledStrokeWidth(g.strokeWidth),
            borderStrokeWidth: _scaledStrokeWidth(2.5),
            borderColor      : Colors.white,
          )).toList(),
        ),
      ),
      if (isAddingNew && newPoints.isNotEmpty)
        PolylineLayer(
          polylines: [
            Polyline(points: newPoints, color: Colors.orange,
                strokeWidth: _scaledStrokeWidth(7.5)),
          ],
        ),
      // 流向矢印（＞型ポリライン）2パス描画で視認性を確保
      // シャドウ（白・やや太め・半透明）を先に描き、その上に矢印本体を重ねる。
      // 縁取りほど主張せず、どの路線色でも矢印が見やすくなる。
      PolylineLayer(polylines: _createFlowArrowPolylines(shadow: true)),
      PolylineLayer(polylines: _createFlowArrowPolylines()),
      ..._createHeadMarkPolylines().map(
        (p) => PolylineLayer(polylines: [p]),
      ),
      // === 勾配矢印スタンプ（→）描画 ===
      MarkerLayer(
        markers: [
          for (final layer in layers)
            if (layer.visible)
              for (final stamp in layer.stamps)
                _buildStampMarker(stamp, layer),
        ],
      ),
    ],
  );

  // ================================================================
  // 勾配矢印スタンプ Marker 生成（ズーム連動 + タップ編集）
  // ================================================================

  /// ズームに応じた勾配矢印スタンプのフォントサイズを返す（baseZoom17 で 24px 相当）。
  double _scaledStampFontSize() {
    const baseZoom      = 17.0;
    const baseFontSize  = 24.0; // 基準サイズ（流向矢印より小さめ）
    final scale = math.pow(2.0, (_currentZoom - baseZoom) * 0.5).toDouble();
    return (baseFontSize * scale).clamp(8.0, baseFontSize * 6);
  }

  Marker _buildStampMarker(ArrowStamp stamp, GutterLayer layer) {
    final fontSize   = _scaledStampFontSize();
    final markerSize = fontSize + 12; // パディング分を加算

    return Marker(
      point : stamp.position,
      width : markerSize,
      height: markerSize,
      child : GestureDetector(
        onTap: () => _showStampEditSheet(stamp, layer),
        child: Transform.rotate(
          // angleDeg は北0°時計回りの方位角。
          // '→' テキストは右向き（東＝方位90°）を基準とするため、
          // (angleDeg - 90) をラジアンに変換して渡す。
          angle: (stamp.angleDeg - 90) * math.pi / 180,
          child: Text(
            '→',
            style: TextStyle(
              fontSize  : fontSize,
              color     : Colors.green,
              fontWeight: FontWeight.bold,
              shadows   : const [
                Shadow(
                  color     : Colors.black38,
                  blurRadius: 4,
                  offset    : Offset(1, 1),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  // ================================================================
  // 勾配矢印スタンプ編集ボトムシート（角度調整・削除）
  // ================================================================

  void _showStampEditSheet(ArrowStamp stamp, GutterLayer layer) {
    double tempAngle = stamp.angleDeg;

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
          padding: EdgeInsets.only(
            bottom: MediaQuery.of(context).viewInsets.bottom,
          ),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 4, 20, 32),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // ドラッグハンドル
                Center(
                  child: Container(
                    width : 40,
                    height: 4,
                    margin: const EdgeInsets.symmetric(vertical: 10),
                    decoration: BoxDecoration(
                      color       : Colors.grey.shade300,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),

                Row(
                  children: [
                    Expanded(
                      child: Text(
                        '勾配矢印の編集',
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                    ),
                    IconButton(
                      icon     : const Icon(Icons.close),
                      onPressed: () => Navigator.pop(ctx),
                    ),
                  ],
                ),
                const Divider(height: 16),

                // 角度表示
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    const Text('角度（北=0°・時計回り）',
                        style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold)),
                    Text('${tempAngle.toStringAsFixed(1)}°',
                        style: const TextStyle(fontSize: 14, fontWeight: FontWeight.bold)),
                  ],
                ),
                Slider(
                  value    : tempAngle,
                  min      : 0,
                  max      : 360,
                  divisions: 360,
                  label    : '${tempAngle.toStringAsFixed(0)}°',
                  onChanged: (v) => setS(() => tempAngle = v),
                ),

                // 方位の簡易ガイド
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceAround,
                  children: [
                    _dirButton('北\n0°',   0,   tempAngle, (v) => setS(() => tempAngle = v)),
                    _dirButton('東\n90°',  90,  tempAngle, (v) => setS(() => tempAngle = v)),
                    _dirButton('南\n180°', 180, tempAngle, (v) => setS(() => tempAngle = v)),
                    _dirButton('西\n270°', 270, tempAngle, (v) => setS(() => tempAngle = v)),
                  ],
                ),
                const SizedBox(height: 20),

                // ボタン行
                Row(
                  children: [
                    // 削除ボタン
                    OutlinedButton.icon(
                      icon : const Icon(Icons.delete_outline, color: Colors.red),
                      label: const Text('削除', style: TextStyle(color: Colors.red)),
                      style: OutlinedButton.styleFrom(
                        side: const BorderSide(color: Colors.red),
                      ),
                      onPressed: () {
                        _saveStateForUndo();
                        setState(() => layer.stamps.remove(stamp));
                        _saveToLocalStorage();
                        Navigator.pop(ctx);
                        _showSnackBar('矢印を削除しました');
                      },
                    ),
                    const Spacer(),
                    OutlinedButton(
                      onPressed: () => Navigator.pop(ctx),
                      child    : const Text('キャンセル'),
                    ),
                    const SizedBox(width: 8),
                    FilledButton(
                      onPressed: () {
                        _saveStateForUndo();
                        setState(() => stamp.angleDeg = tempAngle);
                        _saveToLocalStorage();
                        Navigator.pop(ctx);
                        _showSnackBar('矢印の角度を更新しました');
                      },
                      child: const Text('保存'),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// 方位クイック選択ボタン
  Widget _dirButton(String label, double angle, double current, ValueChanged<double> onTap) =>
      GestureDetector(
        onTap: () => onTap(angle),
        child: Container(
          padding   : const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          decoration: BoxDecoration(
            color       : (current - angle).abs() < 1
                ? Colors.teal.shade700
                : Colors.grey.shade100,
            borderRadius: BorderRadius.circular(8),
          ),
          child: Text(
            label,
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize  : 11,
              fontWeight: FontWeight.bold,
              color     : (current - angle).abs() < 1 ? Colors.white : Colors.black87,
            ),
          ),
        ),
      );



  Widget _buildLayerBadge() {
    final layer = _currentLayer;
    // レイヤーなし・未選択
    final label  = layer != null ? layer.name : 'レイヤー未選択';
    final isNone = layer == null;

    return GestureDetector(
      // タップでドロワーを開く
      onTap: () => _scaffoldKey.currentState?.openEndDrawer(),
      child: Container(
        constraints: const BoxConstraints(maxWidth: 200),
        padding    : const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
        decoration : BoxDecoration(
          color       : isNone
              ? Colors.black45
              : Colors.blue.shade700.withValues(alpha: 0.9),
          borderRadius: BorderRadius.circular(20),
          boxShadow   : const [
            BoxShadow(color: Colors.black26, blurRadius: 4, offset: Offset(0, 2)),
          ],
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children    : [
            Icon(
              isNone ? Icons.layers_clear : Icons.layers,
              color: Colors.white,
              size : 15,
            ),
            const SizedBox(width: 6),
            Flexible(
              child: Text(
                label,
                maxLines  : 1,
                overflow  : TextOverflow.ellipsis,
                style     : const TextStyle(
                  color     : Colors.white,
                  fontSize  : 12,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
            const SizedBox(width: 4),
            const Icon(Icons.arrow_drop_up, color: Colors.white70, size: 16),
          ],
        ),
      ),
    );
  }

  // ================================================================
  // FAB：スマホ向けに2列グリッド＋展開メニュー方式
  // ================================================================

  Widget _buildFabColumn() {
    return Column(
      mainAxisSize     : MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [

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

        // 全体表示
        _roundFab(
          icon     : Icons.fullscreen,
          tooltip  : '全体表示',
          onTap    : _showAllGutters,
          color    : Colors.white,
          iconColor: Colors.blueGrey,
          mini     : true,
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

        // 矢印スタンプモード（2点指定）
        _roundFab(
          icon: Icons.straighten,
          tooltip: '勾配矢印追加（2点指定）',
          onTap: _toggleStamp2PtMode,
          color: isStamp2Pt ? Colors.teal.shade700 : Colors.white,
          iconColor: isStamp2Pt ? Colors.white : Colors.teal.shade700,
          mini: true,
        ),

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

        // URLを更新（クラウド保存）
        FloatingActionButton(
          heroTag        : 'url_update',
          backgroundColor: Colors.blue,
          foregroundColor: Colors.white,
          tooltip        : 'URLを更新（クラウド保存）',
          onPressed      : _uploadAllLayers,
          child          : const Icon(Icons.cloud_sync),
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
              ? const Center(child: Text('レイヤーがありません\n上部のフォルダアイコンから\nGeoJSONファイルを開いてください',
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
                      subtitle: Builder(
                        builder: (_) {
                          // 一括色が設定されているか判定
                          // （categoryKey がなく、全路線が同じ色の場合）
                          Color? bulkColor;
                          if (layer.categoryKey == null && layer.gutters.isNotEmpty) {
                            final firstColor = layer.gutters.first.color;
                            final allSame = layer.gutters.every(
                              (g) => g.color.toARGB32() == firstColor.toARGB32(),
                            );
                            if (allSame) bulkColor = firstColor;
                          }
                          return Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(
                                '${layer.gutters.length} 本'
                                '${layer.categoryKey != null ? " ・ ${layer.categoryKey}" : ""}',
                                style: const TextStyle(fontSize: 12),
                              ),
                              if (bulkColor != null) ...[
                                const SizedBox(width: 6),
                                Container(
                                  width : 12,
                                  height: 12,
                                  decoration: BoxDecoration(
                                    color : bulkColor,
                                    shape : BoxShape.circle,
                                    border: Border.all(color: Colors.black26, width: 0.5),
                                  ),
                                ),
                              ],
                            ],
                          );
                        },
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
                            icon     : const Icon(Icons.tune, size: 20),
                            tooltip  : '一括スタイル変更',
                            onPressed: () => _showBulkStyleDialog(index),
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
                              builder: (dlgCtx) => AlertDialog(
                                title  : const Text('レイヤー削除'),
                                content: Text('「${layer.name}」を削除しますか？'),
                                actions: [
                                  TextButton(
                                    onPressed: () => Navigator.pop(dlgCtx),
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
                                      Navigator.pop(dlgCtx);
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
              // ドロワーを閉じてからダイアログを出すと context が破棄されるため
              // ドロワーを閉じずにダイアログを先に出す
              _createEmptyLayer();
            },
          ),
        ),
      ],
    ),
  );
}