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
      title: '現場踏査GIS',
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
  'gsi_std'       : 'https://cyberjapandata.gsi.go.jp/xyz/std/{z}/{x}/{y}.png',
  'gsi_pale'      : 'https://cyberjapandata.gsi.go.jp/xyz/pale/{z}/{x}/{y}.png',
  'gsi_photo'     : 'https://cyberjapandata.gsi.go.jp/xyz/seamlessphoto/{z}/{x}/{y}.jpg',
};

// タイル選択肢の表示ラベル
const _kTileLabels = {
  'osm'           : 'OpenStreetMap',
  'google_photo'  : '航空写真（Google）',
  'google_hybrid' : 'ハイブリッド（Google）',
  'gsi_std'       : '標準地図（地理院）',
  'gsi_pale'      : '淡色地図（地理院）',
  'gsi_photo'     : '写真（地理院）',
};

// タイルごとのネイティブズーム上限
const _kTileMaxNativeZoom = {
  'osm'           : 19,
  'google_photo'  : 23,
  'google_hybrid' : 23,
  'gsi_std'       : 18,
  'gsi_pale'      : 18,
  'gsi_photo'     : 18,
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
  'layer'          : 'レイヤ名',
  'layerId'        : 'レイヤID',
  'layerVisible'   : 'レイヤ表示',
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

  /// GeoJSON Feature（Point）として出力（エクスポート用：必要属性のみ）
  Map<String, dynamic> toGeoJsonExportFeature({String layerName = ''}) => {
    'type'    : 'Feature',
    'geometry': {
      'type'       : 'Point',
      'coordinates': [
        double.parse(position.longitude.toStringAsFixed(6)),
        double.parse(position.latitude.toStringAsFixed(6)),
      ],
    },
    'properties': {
      'id'      : id,
      'type'    : 'arrow_stamp',
      'angleDeg': angleDeg,
      if (layerName.isNotEmpty) 'layer': layerName,
    },
  };
}
// ================================================================
// ポイントフィーチャ
// ================================================================

/// シンボル種別
enum PointSymbol { circle, triangle, square }

class MapFeaturePoint {
  String id;
  String name;
  String memo;
  LatLng position;
  Color  color;
  PointSymbol symbol;
  Map<String, dynamic> properties; // 外部GeoJSON由来の任意属性

  MapFeaturePoint({
    required this.id,
    this.name     = '',
    this.memo     = '',
    required this.position,
    Color?   color,
    this.symbol   = PointSymbol.circle,
    Map<String, dynamic>? properties,
  }) : color      = color ?? Colors.blue,
       properties = properties ?? {};

  Map<String, dynamic> toJson() => {
    'id'        : id,
    'name'      : name,
    'memo'      : memo,
    'lat'       : position.latitude,
    'lng'       : position.longitude,
    'color'     : color.toARGB32(),
    'symbol'    : symbol.name,
    'properties': properties,
  };

  factory MapFeaturePoint.fromJson(Map<String, dynamic> j) => MapFeaturePoint(
    id        : j['id']?.toString()   ?? '',
    name      : j['name']?.toString() ?? '',
    memo      : j['memo']?.toString() ?? '',
    position  : LatLng(
      (j['lat'] as num).toDouble(),
      (j['lng'] as num).toDouble(),
    ),
    color     : Color(j['color'] as int? ?? Colors.blue.toARGB32()),
    symbol    : PointSymbol.values.firstWhere(
      (e) => e.name == j['symbol'],
      orElse: () => PointSymbol.circle,
    ),
    properties: Map<String, dynamic>.from(j['properties'] as Map? ?? {}),
  );

  /// GeoJSON Feature出力（エクスポート用）
  Map<String, dynamic> toGeoJsonExportFeature({String layerName = ''}) => {
    'type'    : 'Feature',
    'geometry': {
      'type'       : 'Point',
      'coordinates': [
        double.parse(position.longitude.toStringAsFixed(6)),
        double.parse(position.latitude.toStringAsFixed(6)),
      ],
    },
    'properties': {
      'id'    : id,
      'type'  : 'map_point',
      'name'  : name,
      'memo'  : memo,
      if (layerName.isNotEmpty) 'layer': layerName,
      ...properties,
    },
  };

  /// GeoJSON Feature出力（共有用：スタイル含む）
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
      'id'      : id,
      'type'    : 'map_point',
      'name'    : name,
      'memo'    : memo,
      'color'   : color.toARGB32(),
      'symbol'  : symbol.name,
      if (layerName.isNotEmpty) 'layer'  : layerName,
      if (layerId.isNotEmpty)   'layerId': layerId,
      ...properties,
    },
  };
}

// ================================================================
// ポリゴンフィーチャ
// ================================================================

class MapFeaturePolygon {
  String        id;
  String        name;
  String        memo;
  List<LatLng>  points;      // 外周リング（閉じていない点列）
  Color         fillColor;
  double        fillOpacity; // 0.0〜1.0
  Color         strokeColor;
  double        strokeWidth;
  Map<String, dynamic> properties;

  MapFeaturePolygon({
    required this.id,
    this.name         = '',
    this.memo         = '',
    required this.points,
    Color?   fillColor,
    this.fillOpacity  = 0.35,
    Color?   strokeColor,
    this.strokeWidth  = 2.0,
    Map<String, dynamic>? properties,
  }) : fillColor   = fillColor   ?? Colors.blue,
       strokeColor = strokeColor ?? Colors.blue,
       properties  = properties  ?? {};

  Map<String, dynamic> toJson() => {
    'id'          : id,
    'name'        : name,
    'memo'        : memo,
    'points'      : points.map((p) => [p.longitude, p.latitude]).toList(),
    'fillColor'   : fillColor.toARGB32(),
    'fillOpacity' : fillOpacity,
    'strokeColor' : strokeColor.toARGB32(),
    'strokeWidth' : strokeWidth,
    'properties'  : properties,
  };

  factory MapFeaturePolygon.fromJson(Map<String, dynamic> j) => MapFeaturePolygon(
    id          : j['id']?.toString()   ?? '',
    name        : j['name']?.toString() ?? '',
    memo        : j['memo']?.toString() ?? '',
    points      : (j['points'] as List<dynamic>)
        .map((c) => LatLng((c[1] as num).toDouble(), (c[0] as num).toDouble()))
        .toList(),
    fillColor   : Color(j['fillColor']   as int? ?? Colors.blue.toARGB32()),
    fillOpacity : (j['fillOpacity']  as num?)?.toDouble() ?? 0.35,
    strokeColor : Color(j['strokeColor'] as int? ?? Colors.blue.toARGB32()),
    strokeWidth : (j['strokeWidth']  as num?)?.toDouble() ?? 2.0,
    properties  : Map<String, dynamic>.from(j['properties'] as Map? ?? {}),
  );

  /// GeoJSON Feature出力（エクスポート用）
  Map<String, dynamic> toGeoJsonExportFeature({String layerName = ''}) {
    final ring = [...points, if (points.isNotEmpty) points.first]; // 閉合
    return {
      'type'    : 'Feature',
      'geometry': {
        'type'       : 'Polygon',
        'coordinates': [
          ring.map((p) => [
            double.parse(p.longitude.toStringAsFixed(6)),
            double.parse(p.latitude.toStringAsFixed(6)),
          ]).toList(),
        ],
      },
      'properties': {
        'id'  : id,
        'name': name,
        'memo': memo,
        if (layerName.isNotEmpty) 'layer': layerName,
        ...properties,
      },
    };
  }

  /// GeoJSON Feature出力（共有用：スタイル含む）
  Map<String, dynamic> toGeoJsonFeature({String layerName = '', String layerId = ''}) {
    final ring = [...points, if (points.isNotEmpty) points.first];
    return {
      'type'    : 'Feature',
      'geometry': {
        'type'       : 'Polygon',
        'coordinates': [
          ring.map((p) => [
            double.parse(p.longitude.toStringAsFixed(6)),
            double.parse(p.latitude.toStringAsFixed(6)),
          ]).toList(),
        ],
      },
      'properties': {
        'id'         : id,
        'name'       : name,
        'memo'       : memo,
        'fillColor'  : fillColor.toARGB32(),
        'fillOpacity': fillOpacity,
        'strokeColor': strokeColor.toARGB32(),
        'strokeWidth': strokeWidth,
        if (layerName.isNotEmpty) 'layer'  : layerName,
        if (layerId.isNotEmpty)   'layerId': layerId,
        ...properties,
      },
    };
  }
}

// ================================================================
// データモデル
// ================================================================

class GutterLayer {
  String id;
  String name;
  bool   visible;
  /// 'line' | 'point' | 'polygon'  ※既存データは fromJson で 'line' になる
  String layerType;
  List<Gutter>             gutters;
  List<ArrowStamp>         stamps;
  List<MapFeaturePoint>    featurePoints;
  List<MapFeaturePolygon>  featurePolygons;
  String? categoryKey;
  Map<String, Color> categoryColors;

  GutterLayer({
    required this.id,
    required this.name,
    this.visible          = true,
    this.layerType        = 'line',
    required this.gutters,
    List<ArrowStamp>?        stamps,
    List<MapFeaturePoint>?   featurePoints,
    List<MapFeaturePolygon>? featurePolygons,
    this.categoryKey,
    Map<String, Color>? categoryColors,
  }) : stamps          = stamps          ?? [],
       featurePoints   = featurePoints   ?? [],
       featurePolygons = featurePolygons ?? [],
       categoryColors  = categoryColors  ?? {};

  Map<String, dynamic> toJson() => {
    'id'             : id,
    'name'           : name,
    'visible'        : visible,
    'layerType'      : layerType,
    'gutters'        : gutters.map((g) => g.toJson()).toList(),
    'stamps'         : stamps.map((s) => s.toJson()).toList(),
    'featurePoints'  : featurePoints.map((p) => p.toJson()).toList(),
    'featurePolygons': featurePolygons.map((p) => p.toJson()).toList(),
    'categoryKey'    : categoryKey,
    'categoryColors' : categoryColors.map((k, v) => MapEntry(k, v.toARGB32())),
  };

  factory GutterLayer.fromJson(Map<String, dynamic> j) => GutterLayer(
    id      : j['id']?.toString()   ?? '',
    name    : j['name']?.toString() ?? '',
    visible : j['visible'] as bool? ?? true,
    layerType: j['layerType']?.toString() ?? 'line',
    gutters : (j['gutters'] as List<dynamic>? ?? [])
        .map((g) => Gutter.fromJson(g as Map<String, dynamic>))
        .toList(),
    stamps  : (j['stamps'] as List<dynamic>? ?? [])
        .map((s) => ArrowStamp.fromJson(s as Map<String, dynamic>))
        .toList(),
    featurePoints: (j['featurePoints'] as List<dynamic>? ?? [])
        .map((p) => MapFeaturePoint.fromJson(p as Map<String, dynamic>))
        .toList(),
    featurePolygons: (j['featurePolygons'] as List<dynamic>? ?? [])
        .map((p) => MapFeaturePolygon.fromJson(p as Map<String, dynamic>))
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

  // 現在地ピン
  LatLng? _currentPosition;

  // 複数選択モード
  bool _isMultiSelect = false;
  final Set<String> _selectedGutterIds = {};

  // ポイント追加モード
  bool _isAddingPoint = false;

  // ポリゴン追加モード
  bool _isAddingPolygon = false;
  final List<LatLng> _newPolygonPoints = [];

  // 計測モード
  bool _isMeasuring = false;
  final List<LatLng> _measurePoints = [];

  // 検索
  bool _isSearching = false;
  final TextEditingController _searchCtrl = TextEditingController();

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
  List<Gutter> _parseGeoJsonFeatures(List<dynamic> features) {
    final result = <Gutter>[];
    for (final f in features) {
      final geometry = f['geometry'];
      if (geometry == null) continue;
      final geoType = geometry['type'] as String?;
      if (geoType == 'Point' || geoType == 'Polygon' || geoType == 'MultiPolygon') continue;

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

  /// GeoJSON features から一般ポイント（type=='map_point' または未分類Point）を抽出。
  List<MapFeaturePoint> _parseMapPoints(List<dynamic> features) {
    final result = <MapFeaturePoint>[];
    for (final f in features) {
      final geometry = f['geometry'];
      if (geometry == null) continue;
      if (geometry['type'] != 'Point') continue;
      final props = f['properties'] as Map<String, dynamic>? ?? {};
      // arrow_stamp は除外
      if (props['type']?.toString() == 'arrow_stamp') continue;
      final coords = geometry['coordinates'] as List<dynamic>;
      if (coords.length < 2) continue;
      result.add(MapFeaturePoint(
        id        : props['id']?.toString()     ?? 'PT${DateTime.now().millisecondsSinceEpoch}-${result.length}',
        name      : props['name']?.toString()   ?? '',
        memo      : props['memo']?.toString()   ?? '',
        position  : LatLng((coords[1] as num).toDouble(), (coords[0] as num).toDouble()),
        color     : props['color'] != null ? Color((props['color'] as num).toInt()) : Colors.blue,
        symbol    : PointSymbol.values.firstWhere(
          (e) => e.name == props['symbol']?.toString(),
          orElse: () => PointSymbol.circle,
        ),
        properties: Map<String, dynamic>.from(props)..remove('id')..remove('name')..remove('memo')..remove('color')..remove('symbol')..remove('layer')..remove('layerId'),
      ));
    }
    return result;
  }

  /// GeoJSON features からポリゴンを抽出。
  List<MapFeaturePolygon> _parseMapPolygons(List<dynamic> features) {
    final result = <MapFeaturePolygon>[];
    for (final f in features) {
      final geometry = f['geometry'];
      if (geometry == null) continue;
      final geoType = geometry['type'] as String?;

      List<dynamic> ring;
      switch (geoType) {
        case 'Polygon':
          final rings = geometry['coordinates'] as List<dynamic>;
          if (rings.isEmpty) continue;
          ring = rings[0] as List<dynamic>;
        case 'MultiPolygon':
          // MultiPolygon: 最初のポリゴンの外周のみ抽出（簡易対応）
          final polys = geometry['coordinates'] as List<dynamic>;
          if (polys.isEmpty) continue;
          ring = (polys[0] as List<dynamic>)[0] as List<dynamic>;
        default:
          continue;
      }

      final points = ring
          .map((c) => LatLng((c[1] as num).toDouble(), (c[0] as num).toDouble()))
          .toList();
      // 閉合点（始点と同じ終点）を取り除く
      if (points.length > 1 &&
          points.first.latitude  == points.last.latitude &&
          points.first.longitude == points.last.longitude) {
        points.removeLast();
      }
      if (points.length < 3) continue;

      final props = f['properties'] as Map<String, dynamic>? ?? {};
      result.add(MapFeaturePolygon(
        id         : props['id']?.toString()   ?? 'PG${DateTime.now().millisecondsSinceEpoch}-${result.length}',
        name       : props['name']?.toString() ?? '',
        memo       : props['memo']?.toString() ?? '',
        points     : points,
        fillColor  : props['fillColor']   != null ? Color((props['fillColor']   as num).toInt()) : Colors.blue,
        fillOpacity: (props['fillOpacity'] as num?)?.toDouble() ?? 0.35,
        strokeColor: props['strokeColor'] != null ? Color((props['strokeColor'] as num).toInt()) : Colors.blue,
        strokeWidth: (props['strokeWidth'] as num?)?.toDouble() ?? 2.0,
        properties : Map<String, dynamic>.from(props)..remove('id')..remove('name')..remove('memo')..remove('fillColor')..remove('fillOpacity')..remove('strokeColor')..remove('strokeWidth')..remove('layer')..remove('layerId'),
      ));
    }
    return result;
  }

  /// GeoJSONを読み込んでレイヤ種別に応じて分離追加する。
  /// ポイント・ポリゴン・ラインをそれぞれ別レイヤとして追加する。
  void _addParsedLayers(
    List<Gutter>            gutters,
    List<ArrowStamp>        stamps,
    List<MapFeaturePoint>   points,
    List<MapFeaturePolygon> polygons,
    String baseName,
  ) {
    final ts = DateTime.now().millisecondsSinceEpoch;

    // ラインレイヤ
    if (gutters.isNotEmpty) {
      const defaultCategoryKey = 'shape';
      final defaultColors = {
        'BOX'  : Colors.orange,
        '円形'  : Colors.green,
        '開渠'  : Colors.blue,
        '未分類': Colors.grey,
      };
      layers.add(GutterLayer(
        id            : '${ts}_line',
        name          : gutters.length == 1 && points.isEmpty && polygons.isEmpty ? baseName : '$baseName（ライン）',
        layerType     : 'line',
        gutters       : gutters,
        stamps        : stamps,
        categoryKey   : defaultCategoryKey,
        categoryColors: defaultColors,
      ));
    }

    // ポイントレイヤ
    if (points.isNotEmpty) {
      layers.add(GutterLayer(
        id            : '${ts}_point',
        name          : gutters.isEmpty && polygons.isEmpty ? baseName : '$baseName（ポイント）',
        layerType     : 'point',
        gutters       : [],
        featurePoints : points,
      ));
    }

    // ポリゴンレイヤ
    if (polygons.isNotEmpty) {
      layers.add(GutterLayer(
        id              : '${ts}_polygon',
        name            : gutters.isEmpty && points.isEmpty ? baseName : '$baseName（ポリゴン）',
        layerType       : 'polygon',
        gutters         : [],
        featurePolygons : polygons,
      ));
    }
  }

  // 旧メソッド（後方互換・クラウド読み込み等で使用）
  void _addParsedLayerWithStamps(
      List<Gutter> gutters, List<ArrowStamp> stamps, String name) {
    if (gutters.isEmpty) return;
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
        layerType     : 'line',
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
          final layerMap      = <String, List<dynamic>>{};
          final layerNames    = <String, String>{};
          final stampLayerMap = <String, List<dynamic>>{};
          final pointLayerMap = <String, List<dynamic>>{};
          final polygonLayerMap = <String, List<dynamic>>{};

          for (final f in features) {
            final props     = f['properties'] as Map<String, dynamic>? ?? {};
            final layerId   = props['layerId']?.toString() ?? props['layer']?.toString() ?? 'default';
            final layerName = props['layer']?.toString() ?? '共有データ';
            final geoType   = f['geometry']?['type'] as String?;
            final fType     = props['type']?.toString();

            if (geoType == 'Point' && fType == 'arrow_stamp') {
              stampLayerMap.putIfAbsent(layerId, () => []).add(f);
            } else if (geoType == 'Point' && fType == 'map_point') {
              pointLayerMap.putIfAbsent(layerId, () => []).add(f);
            } else if (geoType == 'Polygon' || geoType == 'MultiPolygon') {
              polygonLayerMap.putIfAbsent(layerId, () => []).add(f);
            } else {
              layerMap.putIfAbsent(layerId, () => []).add(f);
            }
            layerNames[layerId] = layerName;
          }

          // 全レイヤIDを収集（ライン・ポイント・ポリゴン問わず）
          final allLayerIds = {
            ...layerMap.keys,
            ...pointLayerMap.keys,
            ...polygonLayerMap.keys,
          };
          if (allLayerIds.isEmpty) {
            _showSnackBar('有効なデータが見つかりませんでした');
            return;
          }

          // FeatureCollection トップレベルの layerStyles を取得
          final rawLayerStyles = (data['layerStyles'] as Map<String, dynamic>?) ?? {};

          int total = 0;
          setState(() {
            for (final layerId in allLayerIds) {
              final layerFeatures   = layerMap[layerId]        ?? [];
              final stampFeatures   = stampLayerMap[layerId]   ?? [];
              final pointFeatures   = pointLayerMap[layerId]   ?? [];
              final polygonFeatures = polygonLayerMap[layerId] ?? [];

              final gutters  = _parseGeoJsonFeatures(layerFeatures);
              final stamps   = _parseArrowStampFeatures(stampFeatures);
              final points   = _parseMapPoints(pointFeatures);
              final polygons = _parseMapPolygons(polygonFeatures);

              total += gutters.length + points.length + polygons.length;

              final styleEntry    = rawLayerStyles[layerId] as Map<String, dynamic>?;
              final String? categoryKey = styleEntry?['categoryKey'] as String? ?? (gutters.isNotEmpty ? 'shape' : null);
              final Map<String, Color> categoryColors = styleEntry != null
                  ? ((styleEntry['categoryColors'] as Map<String, dynamic>?) ?? {})
                      .map((k, v) => MapEntry(k, Color(v as int)))
                  : { 'BOX': Colors.orange, '円形': Colors.green, '開渠': Colors.blue, '未分類': Colors.grey };
              final bool layerVisible = styleEntry?['visible'] as bool? ?? true;

              // layerType の推定
              String layerType = 'line';
              if (gutters.isEmpty && points.isNotEmpty)   layerType = 'point';
              if (gutters.isEmpty && polygons.isNotEmpty) layerType = 'polygon';

              layers.add(GutterLayer(
                id              : layerId,
                name            : layerNames[layerId] ?? '共有データ',
                visible         : layerVisible,
                layerType       : layerType,
                gutters         : gutters,
                stamps          : stamps,
                featurePoints   : points,
                featurePolygons : polygons,
                categoryKey     : categoryKey,
                categoryColors  : categoryColors,
              ));
            }
          });

          if (layers.isNotEmpty) _showAllGutters();
          await _saveToLocalStorage();
          _showSnackBar('$total本の側溝を${layerMap.length}レイヤで読み込みました');
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
          final data     = jsonDecode(utf8.decode(file.bytes!)) as Map<String, dynamic>;
          final features = data['features'] as List<dynamic>? ?? [];
          final gutters  = _parseGeoJsonFeatures(features);
          final stamps   = _parseArrowStampFeatures(features);
          final points   = _parseMapPoints(features);
          final polygons = _parseMapPolygons(features);

          if (gutters.isEmpty && points.isEmpty && polygons.isEmpty) continue;

          final layerName = file.name.replaceAll(
              RegExp(r'\.(geojson|json)$', caseSensitive: false), '');
          setState(() {
            _addParsedLayers(gutters, stamps, points, polygons, layerName);
          });
          totalAdded += gutters.length + points.length + polygons.length;
          layerAdded++;
        } catch (e) {
          _showSnackBar('${file.name} の読み込みエラー: $e');
        }
      }

      if (layerAdded == 0) {
        _showSnackBar('有効なラインがありませんでした');
        return;
      }

      _showSnackBar('$totalAdded 件を $layerAdded レイヤに追加しました');

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
      final features = _buildExportFeatureList();
      if (features.isEmpty) {
        _showSnackBar('エクスポートするデータがありません');
        return;
      }
      final jsonStr = jsonEncode({
        'type'       : 'FeatureCollection',
        'features'   : features,
        'exported_at': DateTime.now().toIso8601String(),
      });
      final anchor = web.HTMLAnchorElement()
        ..href     = 'data:application/geo+json;base64,${base64Encode(utf8.encode(jsonStr))}'
        ..download = 'fieldGIS_${DateTime.now().toIso8601String().substring(0, 10)}.geojson';
      web.document.body!.append(anchor);
      anchor.click();
      anchor.remove();
      _showSnackBar('${features.length}件をエクスポートしました');
    } catch (e) {
      _showSnackBar('エクスポートエラー: $e');
    }
  }

  /// ダウンロード用エクスポート：必要属性のみ・ポイント・ポリゴンも含む
  List<Map<String, dynamic>> _buildExportFeatureList() {
    final lineFeatures = [
      for (final layer in layers)
        for (final g in layer.gutters)
          {
            'type'    : 'Feature',
            'geometry': {
              'type'       : 'LineString',
              'coordinates': g.points.map((p) => [
                double.parse(p.longitude.toStringAsFixed(6)),
                double.parse(p.latitude.toStringAsFixed(6)),
              ]).toList(),
            },
            'properties': {
              'layer'       : layer.name,
              'name'        : g.name,
              'shape'       : g.shape,
              'diameter'    : g.diameter,
              'memo'        : g.memo,
              'showArrow'   : g.showArrow,
              'flowReversed': g.flowReversed,
              'showHeadMark': g.showHeadMark,
            },
          },
    ];
    final stampFeatures = [
      for (final layer in layers)
        for (final s in layer.stamps)
          s.toGeoJsonExportFeature(layerName: layer.name),
    ];
    final pointFeatures = [
      for (final layer in layers)
        for (final p in layer.featurePoints)
          p.toGeoJsonExportFeature(layerName: layer.name),
    ];
    final polygonFeatures = [
      for (final layer in layers)
        for (final p in layer.featurePolygons)
          p.toGeoJsonExportFeature(layerName: layer.name),
    ];
    return [...lineFeatures, ...stampFeatures, ...pointFeatures, ...polygonFeatures];
  }

  // ================================================================
  // GeoJSON アップロード（全レイヤ共有）
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
      // レイヤのスタイル設定（categoryKey・categoryColors）を別途保存
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

    final stampFeatures = [
      for (final layer in layers)
        if (withLayerMeta || layer.visible)
          for (final s in layer.stamps)
            s.toGeoJsonFeature(
              layerName: withLayerMeta ? layer.name : '',
              layerId  : withLayerMeta ? layer.id   : '',
            ),
    ];

    // ポイントフィーチャ
    final pointFeatures = [
      for (final layer in layers)
        if (withLayerMeta || layer.visible)
          for (final p in layer.featurePoints)
            p.toGeoJsonFeature(
              layerName: withLayerMeta ? layer.name : '',
              layerId  : withLayerMeta ? layer.id   : '',
            ),
    ];

    // ポリゴンフィーチャ
    final polygonFeatures = [
      for (final layer in layers)
        if (withLayerMeta || layer.visible)
          for (final p in layer.featurePolygons)
            p.toGeoJsonFeature(
              layerName: withLayerMeta ? layer.name : '',
              layerId  : withLayerMeta ? layer.id   : '',
            ),
    ];

    return [...lineFeatures, ...stampFeatures, ...pointFeatures, ...polygonFeatures];
  }

  // ================================================================
  // モード切り替え
  // ================================================================

  void _clearAllModes() {
    isAddingNew      = false;
    isCutting        = false;
    isDeleting       = false;
    isStamp2Pt       = false;
    _isAddingPoint   = false;
    _isAddingPolygon = false;
    _isMeasuring     = false;
    _stamp2PtFirst   = null;
    newPoints.clear();
    _newPolygonPoints.clear();
    _measurePoints.clear();
  }

  /// 指定した種別のレイヤが選択中でなければ最初の該当レイヤに自動切替する
  void _autoSelectLayerType(String type) {
    final current = _currentLayer;
    if (current != null && current.layerType == type) return; // 既に適切
    final idx = layers.indexWhere((l) => l.layerType == type && l.visible);
    if (idx >= 0) {
      setState(() => selectedLayerIndex = idx);
      _showSnackBar('「${layers[idx].name}」に自動切替しました');
    } else {
      _showSnackBar('${type == 'line' ? 'ライン' : type == 'point' ? 'ポイント' : 'ポリゴン'}レイヤがありません。先にレイヤを作成してください');
    }
  }

  void _toggleAddMode() => setState(() {
    final wasOn = isAddingNew;
    _clearAllModes();
    if (!wasOn) {
      isAddingNew = true;
      _autoSelectLayerType('line');
    }
  });

  void _toggleCutMode() => setState(() {
    final wasOn = isCutting;
    _clearAllModes();
    if (!wasOn) isCutting = true;
  });

  void _toggleDeleteMode() => setState(() {
    final wasOn = isDeleting;
    _clearAllModes();
    if (!wasOn) isDeleting = true;
  });

  void _toggleStamp2PtMode() => setState(() {
    final wasOn = isStamp2Pt;
    _clearAllModes();
    if (!wasOn) isStamp2Pt = true;
  });

  void _toggleAddPointMode() => setState(() {
    final wasOn = _isAddingPoint;
    _clearAllModes();
    if (!wasOn) {
      _isAddingPoint = true;
      _autoSelectLayerType('point');
    }
  });

  void _toggleAddPolygonMode() => setState(() {
    final wasOn = _isAddingPolygon;
    _clearAllModes();
    if (!wasOn) {
      _isAddingPolygon = true;
      _autoSelectLayerType('polygon');
    }
  });

  void _toggleMeasureMode() => setState(() {
    final wasOn = _isMeasuring;
    _clearAllModes();
    if (!wasOn) _isMeasuring = true;
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
      _showSnackBar('レイヤがありません。先にGeoJSONを読み込んでください。');
      return;
    }

    if (isStamp2Pt) {
      _handleStamp2PtTap(point);
      return;
    }

    // 計測モード
    if (_isMeasuring) {
      setState(() => _measurePoints.add(point));
      return;
    }

    // ポイント追加モード
    if (_isAddingPoint) {
      _saveNewPoint(point);
      return;
    }

    // ポリゴン追加モード
    if (_isAddingPolygon) {
      setState(() => _newPolygonPoints.add(point));
      _showSnackBar('${_newPolygonPoints.length}点追加（✓で確定）');
      return;
    }

    if (isDeleting) {
      // ポイント削除（5m以内）
      for (final l in layers) {
        if (!l.visible || l.layerType != 'point') continue;
        for (final pt in l.featurePoints) {
          if (_distance.distance(point, pt.position) <= 5.0) {
            _saveStateForUndo();
            setState(() => l.featurePoints.removeWhere((p) => p.id == pt.id));
            _saveToLocalStorage();
            _showSnackBar('ポイントを削除しました');
            return;
          }
        }
      }
      // ポリゴン削除（内部タップ）
      for (final l in layers.reversed) {
        if (!l.visible || l.layerType != 'polygon') continue;
        for (final pg in l.featurePolygons.reversed) {
          if (_pointInPolygon(point, pg.points)) {
            _saveStateForUndo();
            setState(() => l.featurePolygons.removeWhere((p) => p.id == pg.id));
            _saveToLocalStorage();
            _showSnackBar('ポリゴンを削除しました');
            return;
          }
        }
      }
      // ライン削除
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
      setState(() => newPoints.add(snapped ?? point));
      return;
    }

    // 複数選択モード：全レイヤから近くのラインを選択/解除
    if (_isMultiSelect) {
      Gutter? nearest;
      double  bestDist = double.infinity;
      for (final l in layers) {
        if (!l.visible) continue;
        final g = _findNearestGutterInLayer(point, l);
        if (g == null) continue;
        for (int j = 0; j < g.points.length - 1; j++) {
          final dist = _distance.distance(
            point, _projectOnSegment(point, g.points[j], g.points[j + 1]),
          );
          if (dist < bestDist) { bestDist = dist; nearest = g; }
        }
      }
      if (nearest != null) {
        setState(() {
          if (_selectedGutterIds.contains(nearest!.id)) {
            _selectedGutterIds.remove(nearest.id);
          } else {
            _selectedGutterIds.add(nearest.id);
          }
        });
        _showSnackBar(
          _selectedGutterIds.contains(nearest.id)
            ? '「${nearest.name.isNotEmpty ? nearest.name : nearest.id}」を選択（計${_selectedGutterIds.length}件）'
            : '「${nearest.name.isNotEmpty ? nearest.name : nearest.id}」の選択を解除（計${_selectedGutterIds.length}件）',
        );
      }
      return;
    }

    if (isCutting) {
      _cutLineAtPoint(point, layer);
    } else {
      // ポイント（全レイヤ・5m以内を優先）
      for (final l in layers) {
        if (!l.visible || l.layerType != 'point') continue;
        for (final pt in l.featurePoints) {
          if (_distance.distance(point, pt.position) <= 5.0) {
            _showPointEditSheet(pt, l);
            return;
          }
        }
      }
      // ポリゴン（タップ点が内側）
      for (final l in layers.reversed) {
        if (!l.visible || l.layerType != 'polygon') continue;
        for (final pg in l.featurePolygons.reversed) {
          if (_pointInPolygon(point, pg.points)) {
            _showPolygonEditSheet(pg, l);
            return;
          }
        }
      }
      // ライン
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

  /// 全レイヤの端点・折れ点から最近傍を探してスナップ。
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
      _showSnackBar('レイヤが選択されていません');
      return;
    }
    if (layer.layerType != 'line') {
      _showSnackBar('ラインレイヤを選択してください（現在: ${layer.layerType == 'point' ? 'ポイント' : 'ポリゴン'}レイヤ）');
      return;
    }

    final nameCtrl  = TextEditingController(text: '');
    final shapeCtrl = TextEditingController(text: '---');
    final diamCtrl  = TextEditingController(text: '---');
    final memCtrl   = TextEditingController(text: '');

    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (context, setS) => AlertDialog(
          title  : const Text('新規側溝保存'),
          content: SizedBox(
            width: double.maxFinite,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize      : MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  TextField(
                    controller: nameCtrl,
                    decoration: const InputDecoration(
                      labelText: '側溝名',
                      border   : OutlineInputBorder(),
                      isDense  : true,
                    ),
                  ),
                  const SizedBox(height: 14),
                  _buildAutocomplete(
                    label  : '断面形状',
                    hint   : '開渠 / BOX / 円形',
                    initial: '---',
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
                    initial: '---',
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
                ],
              ),
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
                final shape    = shapeCtrl.text.trim().isEmpty ? '---' : shapeCtrl.text.trim();
                final diameter = diamCtrl.text.trim().isEmpty  ? '---' : diamCtrl.text.trim();
                final memo     = memCtrl.text.trim();
                setState(() {
                  layer.gutters.add(Gutter(
                    id      : 'SG-00$_newGutterCounter',
                    name    : nameCtrl.text,
                    shape   : shape,
                    diameter: diameter,
                    memo    : memo,
                    points  : List.from(newPoints),
                    properties: {
                      'shape'   : shape,
                      'diameter': diameter,
                      'memo'    : memo,
                      'name'    : nameCtrl.text,
                    },
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
      ),
    );
  }

  // ================================================================
  // ポイント追加・保存
  // ================================================================

  void _saveNewPoint(LatLng position) {
    final layer = _currentLayer;
    if (layer == null) {
      _showSnackBar('レイヤが選択されていません');
      return;
    }
    if (layer.layerType != 'point') {
      _showSnackBar('ポイントレイヤを選択してください（現在: ${layer.layerType == 'line' ? 'ライン' : 'ポリゴン'}レイヤ）');
      return;
    }
    final nameCtrl  = TextEditingController();
    final memoCtrl  = TextEditingController();
    Color  selColor  = Colors.blue;
    PointSymbol selSymbol = PointSymbol.circle;

    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setS) => AlertDialog(
          title: const Text('新規ポイント保存'),
          content: SizedBox(
            width: double.maxFinite,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TextField(
                    controller: nameCtrl,
                    decoration: const InputDecoration(
                      labelText: '名称', border: OutlineInputBorder(), isDense: true,
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: memoCtrl,
                    maxLines: 2,
                    decoration: const InputDecoration(
                      labelText: 'メモ', border: OutlineInputBorder(), isDense: true,
                    ),
                  ),
                  const SizedBox(height: 14),
                  const Align(alignment: Alignment.centerLeft,
                      child: Text('シンボル', style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold))),
                  const SizedBox(height: 6),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                    children: PointSymbol.values.map((sym) {
                      final label = sym == PointSymbol.circle ? '●' : sym == PointSymbol.triangle ? '▲' : '■';
                      return GestureDetector(
                        onTap: () => setS(() => selSymbol = sym),
                        child: Container(
                          padding: const EdgeInsets.all(10),
                          decoration: BoxDecoration(
                            border: Border.all(
                              color: selSymbol == sym ? selColor : Colors.grey.shade300,
                              width: 2,
                            ),
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: Text(label, style: TextStyle(fontSize: 22, color: selColor)),
                        ),
                      );
                    }).toList(),
                  ),
                  const SizedBox(height: 14),
                  const Align(alignment: Alignment.centerLeft,
                      child: Text('色', style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold))),
                  const SizedBox(height: 6),
                  Wrap(
                    spacing: 6,
                    children: _kColorPalette.map((c) => GestureDetector(
                      onTap: () => setS(() => selColor = c),
                      child: Container(
                        width: 36, height: 36,
                        decoration: BoxDecoration(
                          color: c, shape: BoxShape.circle,
                          border: Border.all(
                            color: selColor == c ? Colors.black : Colors.transparent, width: 3,
                          ),
                        ),
                      ),
                    )).toList(),
                  ),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('キャンセル')),
            FilledButton(
              onPressed: () {
                _saveStateForUndo();
                setState(() {
                  layer.featurePoints.add(MapFeaturePoint(
                    id      : 'PT${DateTime.now().millisecondsSinceEpoch}',
                    name    : nameCtrl.text,
                    memo    : memoCtrl.text,
                    position: position,
                    color   : selColor,
                    symbol  : selSymbol,
                  ));
                });
                _saveToLocalStorage();
                Navigator.pop(ctx);
                _showSnackBar('ポイントを追加しました');
              },
              child: const Text('保存'),
            ),
          ],
        ),
      ),
    );
  }

  void _showPointEditSheet(MapFeaturePoint pt, GutterLayer layer) {
    final nameCtrl = TextEditingController(text: pt.name);
    final memoCtrl = TextEditingController(text: pt.memo);

    // 外部GeoJSON由来の任意属性コントローラ
    final extraCtrls = {
      for (final e in pt.properties.entries
          .where((e) => !['id','name','memo','color','symbol','layer','layerId','type'].contains(e.key)))
        e.key: TextEditingController(text: e.value?.toString() ?? ''),
    };

    showModalBottomSheet(
      context           : context,
      isScrollControlled: true,
      useRootNavigator  : true,
      backgroundColor   : Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setS) => Padding(
          padding: EdgeInsets.only(
            left: 20, right: 20, top: 20,
            bottom: MediaQuery.of(ctx).viewInsets.bottom + 20,
          ),
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    const Text('ポイント編集', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
                    const Spacer(),
                    IconButton(
                      icon: const Icon(Icons.delete, color: Colors.red),
                      onPressed: () {
                        _saveStateForUndo();
                        setState(() => layer.featurePoints.removeWhere((p) => p.id == pt.id));
                        _saveToLocalStorage();
                        Navigator.pop(ctx);
                        _showSnackBar('ポイントを削除しました');
                      },
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                TextField(controller: nameCtrl, decoration: const InputDecoration(
                  labelText: '名称', border: OutlineInputBorder(), isDense: true,
                )),
                const SizedBox(height: 12),
                TextField(controller: memoCtrl, maxLines: 2, decoration: const InputDecoration(
                  labelText: 'メモ', border: OutlineInputBorder(), isDense: true,
                )),
                if (extraCtrls.isNotEmpty) ...[
                  const SizedBox(height: 14),
                  const Text('その他の属性', style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold)),
                  const SizedBox(height: 6),
                  for (final entry in extraCtrls.entries) ...[
                    TextField(
                      controller: entry.value,
                      decoration: InputDecoration(
                        labelText: entry.key, border: const OutlineInputBorder(), isDense: true,
                      ),
                    ),
                    const SizedBox(height: 8),
                  ],
                ],
                const SizedBox(height: 14),
                const Text('シンボル', style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold)),
                const SizedBox(height: 6),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                  children: PointSymbol.values.map((sym) {
                    final label = sym == PointSymbol.circle ? '●' : sym == PointSymbol.triangle ? '▲' : '■';
                    return GestureDetector(
                      onTap: () => setS(() => pt.symbol = sym),
                      child: Container(
                        padding: const EdgeInsets.all(10),
                        decoration: BoxDecoration(
                          border: Border.all(
                            color: pt.symbol == sym ? pt.color : Colors.grey.shade300, width: 2,
                          ),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Text(label, style: TextStyle(fontSize: 22, color: pt.color)),
                      ),
                    );
                  }).toList(),
                ),
                const SizedBox(height: 14),
                const Text('色', style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold)),
                const SizedBox(height: 6),
                Wrap(
                  spacing: 6,
                  children: _kColorPalette.map((c) => GestureDetector(
                    onTap: () => setS(() => pt.color = c),
                    child: Container(
                      width: 36, height: 36,
                      decoration: BoxDecoration(
                        color: c, shape: BoxShape.circle,
                        border: Border.all(
                          color: pt.color == c ? Colors.black : Colors.transparent, width: 3,
                        ),
                      ),
                    ),
                  )).toList(),
                ),
                const SizedBox(height: 20),
                Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    OutlinedButton(onPressed: () => Navigator.pop(ctx), child: const Text('キャンセル')),
                    const SizedBox(width: 8),
                    FilledButton(
                      onPressed: () {
                        _saveStateForUndo();
                        setState(() {
                          pt.name = nameCtrl.text.trim();
                          pt.memo = memoCtrl.text.trim();
                          for (final e in extraCtrls.entries) {
                            pt.properties[e.key] = e.value.text.trim();
                          }
                        });
                        _saveToLocalStorage();
                        Navigator.pop(ctx);
                        _showSnackBar('保存しました');
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

  // ================================================================
  // ポリゴン追加・保存・編集
  // ================================================================

  void _confirmNewPolygon() {
    if (_newPolygonPoints.length < 3) {
      _showSnackBar('3点以上タップしてください');
      return;
    }
    final layer = _currentLayer;
    if (layer == null) {
      _showSnackBar('レイヤが選択されていません');
      return;
    }
    if (layer.layerType != 'polygon') {
      _showSnackBar('ポリゴンレイヤを選択してください（現在: ${layer.layerType == 'line' ? 'ライン' : 'ポイント'}レイヤ）');
      return;
    }

    final nameCtrl = TextEditingController();
    final memoCtrl = TextEditingController();
    Color  fillColor   = Colors.blue;
    Color  strokeColor = Colors.blue;
    double fillOpacity = 0.35;
    double strokeWidth = 2.0;

    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setS) => AlertDialog(
          title: const Text('新規ポリゴン保存'),
          content: SizedBox(
            width: double.maxFinite,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TextField(controller: nameCtrl, decoration: const InputDecoration(
                    labelText: '名称', border: OutlineInputBorder(), isDense: true,
                  )),
                  const SizedBox(height: 12),
                  TextField(controller: memoCtrl, maxLines: 2, decoration: const InputDecoration(
                    labelText: 'メモ', border: OutlineInputBorder(), isDense: true,
                  )),
                  const SizedBox(height: 14),
                  const Align(alignment: Alignment.centerLeft,
                      child: Text('塗りつぶし色', style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold))),
                  const SizedBox(height: 6),
                  Wrap(spacing: 6, children: _kColorPalette.map((c) => GestureDetector(
                    onTap: () => setS(() => fillColor = c),
                    child: Container(width: 36, height: 36,
                      decoration: BoxDecoration(color: c, shape: BoxShape.circle,
                        border: Border.all(color: fillColor == c ? Colors.black : Colors.transparent, width: 3)),
                    ),
                  )).toList()),
                  const SizedBox(height: 14),
                  Row(children: [
                    const Text('透明度', style: TextStyle(fontSize: 13)),
                    Expanded(child: Slider(
                      value: fillOpacity, min: 0.0, max: 1.0, divisions: 10,
                      label: fillOpacity.toStringAsFixed(1),
                      onChanged: (v) => setS(() => fillOpacity = v),
                    )),
                    Text(fillOpacity.toStringAsFixed(1)),
                  ]),
                  const SizedBox(height: 6),
                  const Align(alignment: Alignment.centerLeft,
                      child: Text('枠線色', style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold))),
                  const SizedBox(height: 6),
                  Wrap(spacing: 6, children: _kColorPalette.map((c) => GestureDetector(
                    onTap: () => setS(() => strokeColor = c),
                    child: Container(width: 36, height: 36,
                      decoration: BoxDecoration(color: c, shape: BoxShape.circle,
                        border: Border.all(color: strokeColor == c ? Colors.black : Colors.transparent, width: 3)),
                    ),
                  )).toList()),
                  const SizedBox(height: 6),
                  Row(children: [
                    const Text('枠線幅', style: TextStyle(fontSize: 13)),
                    Expanded(child: Slider(
                      value: strokeWidth, min: 0.5, max: 8.0, divisions: 15,
                      label: strokeWidth.toStringAsFixed(1),
                      onChanged: (v) => setS(() => strokeWidth = v),
                    )),
                    Text(strokeWidth.toStringAsFixed(1)),
                  ]),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('キャンセル')),
            FilledButton(
              onPressed: () {
                _saveStateForUndo();
                setState(() {
                  layer.featurePolygons.add(MapFeaturePolygon(
                    id         : 'PG${DateTime.now().millisecondsSinceEpoch}',
                    name       : nameCtrl.text,
                    memo       : memoCtrl.text,
                    points     : List.from(_newPolygonPoints),
                    fillColor  : fillColor,
                    fillOpacity: fillOpacity,
                    strokeColor: strokeColor,
                    strokeWidth: strokeWidth,
                  ));
                  _newPolygonPoints.clear();
                });
                _saveToLocalStorage();
                Navigator.pop(ctx);
                _showSnackBar('ポリゴンを追加しました');
              },
              child: const Text('保存'),
            ),
          ],
        ),
      ),
    );
  }

  void _showPolygonEditSheet(MapFeaturePolygon pg, GutterLayer layer) {
    final nameCtrl = TextEditingController(text: pg.name);
    final memoCtrl = TextEditingController(text: pg.memo);
    final extraCtrls = {
      for (final e in pg.properties.entries
          .where((e) => !['id','name','memo','fillColor','fillOpacity','strokeColor','strokeWidth','layer','layerId'].contains(e.key)))
        e.key: TextEditingController(text: e.value?.toString() ?? ''),
    };

    showModalBottomSheet(
      context           : context,
      isScrollControlled: true,
      useRootNavigator  : true,
      backgroundColor   : Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setS) => Padding(
          padding: EdgeInsets.only(
            left: 20, right: 20, top: 20,
            bottom: MediaQuery.of(ctx).viewInsets.bottom + 20,
          ),
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    const Text('ポリゴン編集', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
                    const Spacer(),
                    IconButton(
                      icon: const Icon(Icons.delete, color: Colors.red),
                      onPressed: () {
                        _saveStateForUndo();
                        setState(() => layer.featurePolygons.removeWhere((p) => p.id == pg.id));
                        _saveToLocalStorage();
                        Navigator.pop(ctx);
                        _showSnackBar('ポリゴンを削除しました');
                      },
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                TextField(controller: nameCtrl, decoration: const InputDecoration(
                  labelText: '名称', border: OutlineInputBorder(), isDense: true,
                )),
                const SizedBox(height: 12),
                TextField(controller: memoCtrl, maxLines: 2, decoration: const InputDecoration(
                  labelText: 'メモ', border: OutlineInputBorder(), isDense: true,
                )),
                if (extraCtrls.isNotEmpty) ...[
                  const SizedBox(height: 14),
                  const Text('その他の属性', style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold)),
                  const SizedBox(height: 6),
                  for (final entry in extraCtrls.entries) ...[
                    TextField(controller: entry.value, decoration: InputDecoration(
                      labelText: entry.key, border: const OutlineInputBorder(), isDense: true,
                    )),
                    const SizedBox(height: 8),
                  ],
                ],
                const SizedBox(height: 14),
                const Text('塗りつぶし色', style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold)),
                const SizedBox(height: 6),
                Wrap(spacing: 6, children: _kColorPalette.map((c) => GestureDetector(
                  onTap: () => setS(() => pg.fillColor = c),
                  child: Container(width: 36, height: 36,
                    decoration: BoxDecoration(color: c, shape: BoxShape.circle,
                      border: Border.all(color: pg.fillColor == c ? Colors.black : Colors.transparent, width: 3)),
                  ),
                )).toList()),
                const SizedBox(height: 10),
                Row(children: [
                  const Text('透明度', style: TextStyle(fontSize: 13)),
                  Expanded(child: Slider(
                    value: pg.fillOpacity, min: 0.0, max: 1.0, divisions: 10,
                    label: pg.fillOpacity.toStringAsFixed(1),
                    onChanged: (v) => setS(() => pg.fillOpacity = v),
                  )),
                  Text(pg.fillOpacity.toStringAsFixed(1)),
                ]),
                const SizedBox(height: 6),
                const Text('枠線色', style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold)),
                const SizedBox(height: 6),
                Wrap(spacing: 6, children: _kColorPalette.map((c) => GestureDetector(
                  onTap: () => setS(() => pg.strokeColor = c),
                  child: Container(width: 36, height: 36,
                    decoration: BoxDecoration(color: c, shape: BoxShape.circle,
                      border: Border.all(color: pg.strokeColor == c ? Colors.black : Colors.transparent, width: 3)),
                  ),
                )).toList()),
                const SizedBox(height: 6),
                Row(children: [
                  const Text('枠線幅', style: TextStyle(fontSize: 13)),
                  Expanded(child: Slider(
                    value: pg.strokeWidth, min: 0.5, max: 8.0, divisions: 15,
                    label: pg.strokeWidth.toStringAsFixed(1),
                    onChanged: (v) => setS(() => pg.strokeWidth = v),
                  )),
                  Text(pg.strokeWidth.toStringAsFixed(1)),
                ]),
                const SizedBox(height: 20),
                Row(mainAxisAlignment: MainAxisAlignment.end, children: [
                  OutlinedButton(onPressed: () => Navigator.pop(ctx), child: const Text('キャンセル')),
                  const SizedBox(width: 8),
                  FilledButton(
                    onPressed: () {
                      _saveStateForUndo();
                      setState(() {
                        pg.name = nameCtrl.text.trim();
                        pg.memo = memoCtrl.text.trim();
                        for (final e in extraCtrls.entries) {
                          pg.properties[e.key] = e.value.text.trim();
                        }
                      });
                      _saveToLocalStorage();
                      Navigator.pop(ctx);
                      _showSnackBar('保存しました');
                    },
                    child: const Text('保存'),
                  ),
                ]),
              ],
            ),
          ),
        ),
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
      _showSnackBar('レイヤが選択されていません');
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

  // ================================================================
  // 複数選択モード
  // ================================================================

  void _toggleMultiSelect() {
    setState(() {
      _isMultiSelect = !_isMultiSelect;
      if (!_isMultiSelect) _selectedGutterIds.clear();
    });
  }

  /// 選択中の Gutter をすべてのレイヤから収集する
  List<({Gutter gutter, GutterLayer layer, int layerIdx, int gutterIdx})>
      _getSelectedGutters() {
    final result = <({Gutter gutter, GutterLayer layer, int layerIdx, int gutterIdx})>[];
    for (int li = 0; li < layers.length; li++) {
      final layer = layers[li];
      for (int gi = 0; gi < layer.gutters.length; gi++) {
        final g = layer.gutters[gi];
        if (_selectedGutterIds.contains(g.id)) {
          result.add((gutter: g, layer: layer, layerIdx: li, gutterIdx: gi));
        }
      }
    }
    return result;
  }

  void _showBulkEditDialog() {
    if (_selectedGutterIds.isEmpty) {
      _showSnackBar('ラインが選択されていません');
      return;
    }

    // 編集対象
    final selected = _getSelectedGutters();
    final count    = selected.length;

    // 各フィールド：null = 変更なし
    bool?   bulkShowArrow;
    bool?   bulkShowHeadMark;
    GutterLayer? bulkLayer;

    // 値が全選択で統一されているか確認してプレースホルダ表示用
    final shapes    = selected.map((e) => e.gutter.shape).toSet();
    final diams     = selected.map((e) => e.gutter.diameter).toSet();
    final memos     = selected.map((e) => e.gutter.memo).toSet();
    final initShape = shapes.length    == 1 ? shapes.first    : null;
    final initDiam  = diams.length     == 1 ? diams.first     : null;
    final initMemo  = memos.length     == 1 ? memos.first     : null;

    final shapeCtrl = TextEditingController(text: initShape ?? '');
    final diamCtrl  = TextEditingController(text: initDiam  ?? '');
    final memoCtrl  = TextEditingController(text: initMemo  ?? '');

    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setS) => AlertDialog(
          title: Text('一括編集（$count件選択中）'),
          content: SizedBox(
            width: double.maxFinite,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    '入力したフィールドのみ変更されます。\n空欄のフィールドは変更されません。',
                    style: TextStyle(fontSize: 12, color: Colors.grey),
                  ),
                  const SizedBox(height: 14),

                  // 断面形状
                  _buildAutocomplete(
                    label  : '断面形状',
                    hint   : initShape != null ? initShape : '（複数の値）',
                    initial: initShape ?? '',
                    options: _kShapeOptions,
                    display: (o) => _kShapeLabels[o] ?? o,
                    filter : (o, v) =>
                        o.toLowerCase().contains(v.toLowerCase()) ||
                        (_kShapeLabels[o] ?? '').contains(v),
                    ctrl   : shapeCtrl,
                  ),
                  const SizedBox(height: 12),

                  // 口径
                  _buildAutocomplete(
                    label  : '口径',
                    hint   : initDiam != null ? initDiam : '（複数の値）',
                    initial: initDiam ?? '',
                    options: _kDiameterOptions,
                    display: (o) => o,
                    filter : (o, v) => o.contains(v),
                    ctrl   : diamCtrl,
                  ),
                  const SizedBox(height: 12),

                  // メモ
                  TextField(
                    controller: memoCtrl,
                    maxLines  : 2,
                    decoration: InputDecoration(
                      labelText: 'メモ',
                      hintText : initMemo != null ? initMemo : '（複数の値）',
                      border   : const OutlineInputBorder(),
                      isDense  : true,
                    ),
                  ),
                  const SizedBox(height: 14),

                  // 流向矢印
                  const Text('流向矢印', style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold)),
                  Row(
                    children: [
                      ChoiceChip(
                        label   : const Text('変更なし'),
                        selected: bulkShowArrow == null,
                        onSelected: (_) => setS(() => bulkShowArrow = null),
                      ),
                      const SizedBox(width: 6),
                      ChoiceChip(
                        label   : const Text('ON'),
                        selected: bulkShowArrow == true,
                        onSelected: (_) => setS(() => bulkShowArrow = true),
                      ),
                      const SizedBox(width: 6),
                      ChoiceChip(
                        label   : const Text('OFF'),
                        selected: bulkShowArrow == false,
                        onSelected: (_) => setS(() => bulkShowArrow = false),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),

                  // 最上流マーク
                  const Text('最上流マーク', style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold)),
                  Row(
                    children: [
                      ChoiceChip(
                        label   : const Text('変更なし'),
                        selected: bulkShowHeadMark == null,
                        onSelected: (_) => setS(() => bulkShowHeadMark = null),
                      ),
                      const SizedBox(width: 6),
                      ChoiceChip(
                        label   : const Text('ON'),
                        selected: bulkShowHeadMark == true,
                        onSelected: (_) => setS(() => bulkShowHeadMark = true),
                      ),
                      const SizedBox(width: 6),
                      ChoiceChip(
                        label   : const Text('OFF'),
                        selected: bulkShowHeadMark == false,
                        onSelected: (_) => setS(() => bulkShowHeadMark = false),
                      ),
                    ],
                  ),
                  const SizedBox(height: 14),

                  // レイヤ移動
                  const Text('レイヤ移動', style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold)),
                  const SizedBox(height: 6),
                  Container(
                    padding    : const EdgeInsets.symmetric(horizontal: 12),
                    decoration : BoxDecoration(
                      border       : Border.all(color: Colors.grey.shade400),
                      borderRadius : BorderRadius.circular(4),
                    ),
                    child: DropdownButton<GutterLayer>(
                      value      : bulkLayer,
                      hint       : const Text('変更なし'),
                      isExpanded : true,
                      underline  : const SizedBox.shrink(),
                      items: layers.map((l) => DropdownMenuItem(
                        value: l,
                        child: Text(l.name),
                      )).toList(),
                      onChanged: (v) => setS(() => bulkLayer = v),
                    ),
                  ),
                ],
              ),
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
                final newShape    = shapeCtrl.text.trim().isNotEmpty ? shapeCtrl.text.trim() : null;
                final newDiameter = diamCtrl.text.trim().isNotEmpty  ? diamCtrl.text.trim()  : null;
                final newMemo     = memoCtrl.text.trim().isNotEmpty  ? memoCtrl.text.trim()  : null;

                setState(() {
                  for (final s in selected) {
                    final g = s.gutter;
                    if (newShape    != null) { g.shape    = newShape;    g.properties['shape']    = newShape; }
                    if (newDiameter != null) { g.diameter = newDiameter; g.properties['diameter'] = newDiameter; }
                    if (newMemo     != null) { g.memo     = newMemo;     g.properties['memo']     = newMemo; }
                    if (bulkShowArrow    != null) g.showArrow    = bulkShowArrow!;
                    if (bulkShowHeadMark != null) g.showHeadMark = bulkShowHeadMark!;

                    // レイヤ移動
                    if (bulkLayer != null && bulkLayer != s.layer) {
                      s.layer.gutters.remove(g);
                      bulkLayer!.gutters.add(g);
                    }
                  }
                  _selectedGutterIds.clear();
                  _isMultiSelect = false;
                });
                _saveToLocalStorage();
                Navigator.pop(ctx);
                _showSnackBar('$count件を一括編集しました');
              },
              child: const Text('適用'),
            ),
          ],
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
    final pts = <LatLng>[
      ...layers.where((l) => l.visible).expand((l) => l.gutters).expand((g) => g.points),
      ...layers.where((l) => l.visible).expand((l) => l.featurePoints).map((p) => p.position),
      ...layers.where((l) => l.visible).expand((l) => l.featurePolygons).expand((pg) => pg.points),
      ...layers.where((l) => l.visible).expand((l) => l.stamps).map((s) => s.position),
    ];
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
      final latlng = LatLng(pos.latitude, pos.longitude);
      setState(() => _currentPosition = latlng);
      _mapController.move(latlng, 17.0);
    } catch (e) {
      _showSnackBar('位置情報取得失敗: $e');
    }
  }

  // ================================================================
  // レイヤ管理
  // ================================================================

  void _renameLayer(int index) {
    final ctrl = TextEditingController(text: layers[index].name);
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title  : const Text('レイヤ名変更'),
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
    String layerType = 'line';
    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setS) => AlertDialog(
          title  : const Text('新規レイヤ作成'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller : ctrl,
                autofocus  : true,
                decoration : const InputDecoration(
                  labelText: 'レイヤ名',
                  hintText : '例）区域A・幹線など',
                  border   : OutlineInputBorder(),
                  isDense  : true,
                ),
              ),
              const SizedBox(height: 16),
              const Align(
                alignment: Alignment.centerLeft,
                child: Text('データ種別', style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold)),
              ),
              const SizedBox(height: 8),
              SegmentedButton<String>(
                segments: const [
                  ButtonSegment(value: 'line',    icon: Icon(Icons.polyline,          size: 16), label: Text('ライン')),
                  ButtonSegment(value: 'point',   icon: Icon(Icons.place,             size: 16), label: Text('ポイント')),
                  ButtonSegment(value: 'polygon', icon: Icon(Icons.pentagon_outlined, size: 16), label: Text('ポリゴン')),
                ],
                selected: {layerType},
                onSelectionChanged: (s) => setS(() => layerType = s.first),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child    : const Text('キャンセル'),
            ),
            FilledButton(
              onPressed: () {
                final name = ctrl.text.trim();
                if (name.isEmpty) return;
                setState(() {
                  layers.add(GutterLayer(
                    id            : DateTime.now().millisecondsSinceEpoch.toString(),
                    name          : name,
                    layerType     : layerType,
                    gutters       : [],
                    categoryKey   : layerType == 'line' ? 'shape' : null,
                    categoryColors: layerType == 'line' ? {
                      'BOX'  : Colors.orange,
                      '円形'  : Colors.green,
                      '開渠'  : Colors.blue,
                      '未分類': Colors.grey,
                    } : {},
                  ));
                  selectedLayerIndex = layers.length - 1;
                });
                _saveToLocalStorage();
                Navigator.pop(ctx);
                Navigator.of(context).maybePop();
              },
              child: const Text('作成'),
            ),
          ],
        ),
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
  /// - 'layer' キーはレイヤ順、それ以外はアルファベット順
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
      // レイヤ登録順にソート
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
  // 一括スタイル変更（レイヤ内の全路線）
  // ================================================================

  void _showBulkStyleDialog(int layerIndex) {
    final layer = layers[layerIndex];
    if (layer.gutters.isEmpty) {
      _showSnackBar('このレイヤに路線がありません');
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
  /// 白アウトラインは矢印本体より2px太くし、本体の下レイヤに描くことで
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
    title: _isSearching
        ? TextField(
            controller  : _searchCtrl,
            autofocus   : true,
            style       : const TextStyle(color: Colors.white),
            cursorColor : Colors.white70,
            decoration  : const InputDecoration(
              hintText     : '名称・メモ・属性で検索…',
              hintStyle    : TextStyle(color: Colors.white54),
              border       : InputBorder.none,
            ),
            onSubmitted: _runSearch,
            textInputAction: TextInputAction.search,
          )
        : Text(
            isAddingNew
                ? '新規追加モード（${newPoints.length}点）'
                : isCutting
                    ? '切断モード'
                    : isDeleting
                        ? '削除モード'
                        : isStamp2Pt
                            ? '勾配矢印モード（${_stamp2PtFirst == null ? "1点目をタップ" : "2点目をタップ"}）'
                            : _isAddingPoint
                                ? 'ポイント追加モード'
                                : _isAddingPolygon
                                    ? 'ポリゴン追加モード（${_newPolygonPoints.length}点）'
                                    : _isMeasuring
                                        ? '計測モード'
                                        : '現場踏査GIS',
            style: const TextStyle(fontSize: 15, fontWeight: FontWeight.bold),
          ),
    bottom: (!isAddingNew && !isCutting && !isDeleting && !isStamp2Pt &&
             !_isAddingPoint && !_isAddingPolygon && !_isMeasuring && !_isSearching)
        ? PreferredSize(
            preferredSize: const Size.fromHeight(20),
            child: Padding(
              padding: const EdgeInsets.only(bottom: 5),
              child: Text(
                _currentLayer != null
                    ? '編集中レイヤ：${_currentLayer!.name}'
                    : 'レイヤ未選択',
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
                    : _isAddingPoint
                        ? Colors.deepOrange
                        : _isAddingPolygon
                            ? Colors.purple.shade300
                            : _isMeasuring
                                ? Colors.brown
                                : Colors.blue,
    foregroundColor: Colors.white,
    actions: [
      // 検索
      IconButton(
        icon     : Icon(_isSearching ? Icons.close : Icons.search),
        tooltip  : _isSearching ? '検索を閉じる' : '検索',
        onPressed: _toggleSearch,
      ),
      // 検索中：実行ボタン
      if (_isSearching)
        IconButton(
          icon     : const Icon(Icons.arrow_forward),
          tooltip  : '検索実行',
          onPressed: () => _runSearch(_searchCtrl.text),
        ),
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
                        e.key == 'osm'         ? Icons.map
                          : e.key == 'gsi_std'   ? Icons.terrain
                          : e.key == 'gsi_pale'  ? Icons.map_outlined
                          : e.key == 'gsi_photo' ? Icons.satellite_alt
                          : e.key == 'google_hybrid' ? Icons.map_outlined
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
        tooltip  : 'レイヤ管理',
        onPressed: () => _scaffoldKey.currentState?.openEndDrawer(),
      ),
    ],
  );

  Widget _buildBody() => Stack(
    children: [
      _buildMap(),
      // モード中の操作ガイド（画面上部に薄く表示）
      if (isAddingNew || isCutting || isDeleting || isStamp2Pt ||
          _isAddingPoint || _isAddingPolygon || _isMultiSelect || _isMeasuring)
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
                            : isStamp2Pt
                                ? Colors.teal
                                : _isAddingPoint
                                    ? Colors.deepOrange
                                    : _isAddingPolygon
                                        ? Colors.purple.shade300
                                        : _isMeasuring
                                            ? Colors.brown
                                            : Colors.indigo)
                .withValues(alpha: 0.88),
            padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 12),
            child: Text(
              isAddingNew
                  ? '地図をタップして点を追加 → ✔で保存'
                  : isCutting
                      ? 'ラインをタップして切断'
                      : isDeleting
                          ? 'タップしたフィーチャを削除（ライン・ポイント・ポリゴン対応）'
                          : isStamp2Pt
                              ? (_stamp2PtFirst == null
                                  ? '① 始点（高い側）をタップ'
                                  : '② 終点（低い側）をタップ → 角度を自動計算します')
                              : _isAddingPoint
                                  ? 'タップした場所にポイントを追加（ポイントレイヤを選択中）'
                                  : _isAddingPolygon
                                      ? 'タップして頂点を追加 → 3点以上で✔ボタンが出現'
                                      : _isMeasuring
                                          ? _measurePoints.isEmpty
                                              ? 'タップして計測開始（距離・面積）'
                                              : _buildMeasureLabel()
                                          : _isMultiSelect
                                              ? 'タップしてラインを選択 / 再タップで解除'
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
      // 左下：選択中レイヤバッジ（常時表示）
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
      maxZoom      : 22.0,
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
        userAgentPackageName: 'com.example.fieldGIS',
        maxNativeZoom: _kTileMaxNativeZoom[currentTile] ?? 19,
        maxZoom      : 22,
      ),

      // === ポリゴン描画（塗りつぶし＋枠線） ===
      ...layers.where((l) => l.visible && l.layerType == 'polygon').map(
        (layer) => PolygonLayer(
          polygons: layer.featurePolygons
              .where((pg) => _isPolygonVisible(pg))
              .map((pg) => Polygon(
                points         : pg.points,
                color          : pg.fillColor.withValues(alpha: pg.fillOpacity),
                borderColor    : pg.strokeColor,
                borderStrokeWidth: _scaledStrokeWidth(pg.strokeWidth),
              )).toList(),
        ),
      ),

      // === ライン描画 ===
      ...layers.where((l) => l.visible && l.layerType == 'line').map(
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

      // 複数選択ハイライト
      if (_isMultiSelect && _selectedGutterIds.isNotEmpty)
        PolylineLayer(
          polylines: [
            for (final layer in layers)
              for (final g in layer.gutters)
                if (_selectedGutterIds.contains(g.id))
                  Polyline(
                    points           : g.points,
                    color            : Colors.indigo.withValues(alpha: 0.7),
                    strokeWidth      : _scaledStrokeWidth(g.strokeWidth + 5),
                    borderStrokeWidth: _scaledStrokeWidth(3),
                    borderColor      : Colors.white,
                  ),
          ],
        ),

      // ライン追加中プレビュー
      if (isAddingNew && newPoints.isNotEmpty)
        PolylineLayer(polylines: [
          Polyline(points: newPoints, color: Colors.orange,
              strokeWidth: _scaledStrokeWidth(7.5)),
        ]),

      // ポリゴン追加中プレビュー
      if (_isAddingPolygon && _newPolygonPoints.isNotEmpty) ...[
        if (_newPolygonPoints.length >= 2)
          PolylineLayer(polylines: [
            Polyline(
              points     : [..._newPolygonPoints, _newPolygonPoints.first],
              color      : Colors.teal.withValues(alpha: 0.8),
              strokeWidth: _scaledStrokeWidth(3),
            ),
          ]),
        PolygonLayer(polygons: [
          if (_newPolygonPoints.length >= 3)
            Polygon(
              points   : _newPolygonPoints,
              color    : Colors.teal.withValues(alpha: 0.2),
              borderStrokeWidth: 0,
              borderColor: Colors.transparent,
            ),
        ]),
      ],

      // 計測ラインプレビュー
      if (_isMeasuring && _measurePoints.length >= 2)
        PolylineLayer(polylines: [
          Polyline(
            points     : _measurePoints,
            color      : Colors.brown,
            strokeWidth: _scaledStrokeWidth(3),
            strokeCap  : StrokeCap.round,
          ),
        ]),
      if (_isMeasuring && _measurePoints.length >= 3)
        PolygonLayer(polygons: [
          Polygon(
            points   : _measurePoints,
            color    : Colors.brown.withValues(alpha: 0.15),
            borderStrokeWidth: 0,
            borderColor: Colors.transparent,
          ),
        ]),

      // 流向矢印
      PolylineLayer(polylines: _createFlowArrowPolylines(shadow: true)),
      PolylineLayer(polylines: _createFlowArrowPolylines()),
      ..._createHeadMarkPolylines().map((p) => PolylineLayer(polylines: [p])),

      // === ポイント・スタンプ・現在地 Marker ===
      MarkerLayer(
        markers: [
          // 勾配矢印スタンプ
          for (final layer in layers)
            if (layer.visible)
              for (final stamp in layer.stamps)
                _buildStampMarker(stamp, layer),

          // 一般ポイント（画面内のみ描画）
          for (final layer in layers)
            if (layer.visible && layer.layerType == 'point')
              for (final pt in layer.featurePoints)
                if (_isLatLngVisible(pt.position))
                  _buildPointMarker(pt, layer),

          // ポリゴンラベル（画面内・ズーム14以上のみ）
          if (_currentZoom >= 14)
            for (final layer in layers)
              if (layer.visible && layer.layerType == 'polygon')
                for (final pg in layer.featurePolygons)
                  if (pg.name.isNotEmpty && _isPolygonLabelVisible(pg))
                    _buildPolygonLabelMarker(pg),

          // 現在地ピン
          if (_currentPosition != null)
            _buildCurrentPositionMarker(_currentPosition!),
        ],
      ),
    ],
  );

  // ================================================================
  // 描画最適化：画面外カリング
  // ================================================================

  /// カメラの現在バウンダリ（マージン付き）
  LatLngBounds? get _cameraBounds {
    try {
      return _mapController.camera.visibleBounds;
    } catch (_) {
      return null;
    }
  }

  /// ポイントが画面内（マージン10%付き）かどうか
  bool _isLatLngVisible(LatLng pos) {
    final bounds = _cameraBounds;
    if (bounds == null) return true;
    final latSpan = (bounds.north - bounds.south) * 0.1;
    final lngSpan = (bounds.east  - bounds.west)  * 0.1;
    return pos.latitude  >= bounds.south - latSpan &&
           pos.latitude  <= bounds.north + latSpan &&
           pos.longitude >= bounds.west  - lngSpan &&
           pos.longitude <= bounds.east  + lngSpan;
  }

  /// ポリゴンが画面と交差するかどうか（バウンディングボックス判定）
  bool _isPolygonVisible(MapFeaturePolygon pg) {
    if (pg.points.isEmpty) return false;
    final bounds = _cameraBounds;
    if (bounds == null) return true;
    final lats = pg.points.map((p) => p.latitude);
    final lngs = pg.points.map((p) => p.longitude);
    final minLat = lats.reduce((a, b) => a < b ? a : b);
    final maxLat = lats.reduce((a, b) => a > b ? a : b);
    final minLng = lngs.reduce((a, b) => a < b ? a : b);
    final maxLng = lngs.reduce((a, b) => a > b ? a : b);
    return maxLat >= bounds.south && minLat <= bounds.north &&
           maxLng >= bounds.west  && minLng <= bounds.east;
  }

  /// ポリゴンの重心が画面内かどうか（ラベル表示用）
  bool _isPolygonLabelVisible(MapFeaturePolygon pg) {
    if (pg.points.isEmpty) return false;
    final centroidLat = pg.points.map((p) => p.latitude ).reduce((a, b) => a + b) / pg.points.length;
    final centroidLng = pg.points.map((p) => p.longitude).reduce((a, b) => a + b) / pg.points.length;
    return _isLatLngVisible(LatLng(centroidLat, centroidLng));
  }

  // ================================================================
  // ポイントMarker生成
  // ================================================================

  Marker _buildPointMarker(MapFeaturePoint pt, GutterLayer layer) {
    final fontSize   = _scaledStampFontSize();
    final markerSize = fontSize + 16;
    final symbol     = pt.symbol == PointSymbol.circle  ? '●'
                     : pt.symbol == PointSymbol.triangle ? '▲'
                     : '■';
    return Marker(
      point : pt.position,
      width : markerSize,
      height: markerSize,
      child : GestureDetector(
        onTap: () => _showPointEditSheet(pt, layer),
        child: Stack(
          alignment: Alignment.center,
          children: [
            // 影（白）
            Text(symbol,
              style: TextStyle(
                fontSize  : fontSize,
                foreground: Paint()
                  ..style       = PaintingStyle.stroke
                  ..strokeWidth = 3
                  ..color       = Colors.white,
              ),
            ),
            // 本体
            Text(symbol,
              style: TextStyle(fontSize: fontSize, color: pt.color),
            ),
            // 名称ラベル（ズーム16以上）
            if (_currentZoom >= 16 && pt.name.isNotEmpty)
              Positioned(
                bottom: 0,
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 3, vertical: 1),
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: 0.85),
                    borderRadius: BorderRadius.circular(3),
                  ),
                  child: Text(pt.name,
                    style: const TextStyle(fontSize: 9, color: Colors.black87),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  // ================================================================
  // ポリゴンラベルMarker生成
  // ================================================================

  Marker _buildPolygonLabelMarker(MapFeaturePolygon pg) {
    final centroidLat = pg.points.map((p) => p.latitude ).reduce((a, b) => a + b) / pg.points.length;
    final centroidLng = pg.points.map((p) => p.longitude).reduce((a, b) => a + b) / pg.points.length;
    return Marker(
      point : LatLng(centroidLat, centroidLng),
      width : 120,
      height: 32,
      child : GestureDetector(
        onTap: () {
          // 所属レイヤを探して編集シートを開く
          for (final layer in layers) {
            if (layer.featurePolygons.any((p) => p.id == pg.id)) {
              _showPolygonEditSheet(pg, layer);
              return;
            }
          }
        },
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
          decoration: BoxDecoration(
            color       : Colors.white.withValues(alpha: 0.85),
            borderRadius: BorderRadius.circular(4),
            border      : Border.all(color: pg.strokeColor.withValues(alpha: 0.6), width: 1),
          ),
          child: Text(
            pg.name,
            textAlign: TextAlign.center,
            overflow : TextOverflow.ellipsis,
            style    : const TextStyle(fontSize: 10, color: Colors.black87, fontWeight: FontWeight.bold),
          ),
        ),
      ),
    );
  }

  // ================================================================
  // ポリゴンタップ検出（_addPoint から呼ばれる通常モード用）
  // ================================================================

  /// タップ点がどのポリゴン内にあるか判定（最前面のもの）
  /// Ray casting アルゴリズムで点がポリゴン内かどうか判定
  bool _pointInPolygon(LatLng point, List<LatLng> polygon) {
    if (polygon.length < 3) return false;
    int crossings = 0;
    for (int i = 0; i < polygon.length; i++) {
      final a = polygon[i];
      final b = polygon[(i + 1) % polygon.length];
      if (((a.latitude <= point.latitude && point.latitude < b.latitude) ||
           (b.latitude <= point.latitude && point.latitude < a.latitude)) &&
          (point.longitude < (b.longitude - a.longitude) *
              (point.latitude - a.latitude) /
              (b.latitude - a.latitude) + a.longitude)) {
        crossings++;
      }
    }
    return crossings.isOdd;
  }

  // ================================================================
  // 検索
  // ================================================================

  void _toggleSearch() {
    setState(() {
      _isSearching = !_isSearching;
      if (!_isSearching) _searchCtrl.clear();
    });
  }

  /// 名称・メモ・属性値でフィーチャを検索し、最初のヒットにカメラを飛ばす
  void _runSearch(String query) {
    if (query.trim().isEmpty) return;
    final q = query.trim().toLowerCase();

    // ライン
    for (final layer in layers) {
      for (final g in layer.gutters) {
        if (g.name.toLowerCase().contains(q) ||
            g.memo.toLowerCase().contains(q) ||
            g.shape.toLowerCase().contains(q) ||
            g.diameter.toLowerCase().contains(q)) {
          if (g.points.isNotEmpty) {
            _mapController.move(g.points.first, math.max(_currentZoom, 17.0));
            _showSnackBar('「${g.name.isNotEmpty ? g.name : g.id}」（${layer.name}）に移動しました');
            return;
          }
        }
      }
      // ポイント
      for (final pt in layer.featurePoints) {
        if (pt.name.toLowerCase().contains(q) || pt.memo.toLowerCase().contains(q) ||
            pt.properties.values.any((v) => v.toString().toLowerCase().contains(q))) {
          _mapController.move(pt.position, math.max(_currentZoom, 17.0));
          _showSnackBar('「${pt.name.isNotEmpty ? pt.name : pt.id}」（${layer.name}）に移動しました');
          return;
        }
      }
      // ポリゴン
      for (final pg in layer.featurePolygons) {
        if (pg.name.toLowerCase().contains(q) || pg.memo.toLowerCase().contains(q) ||
            pg.properties.values.any((v) => v.toString().toLowerCase().contains(q))) {
          if (pg.points.isNotEmpty) {
            final centroid = LatLng(
              pg.points.map((p) => p.latitude ).reduce((a, b) => a + b) / pg.points.length,
              pg.points.map((p) => p.longitude).reduce((a, b) => a + b) / pg.points.length,
            );
            _mapController.move(centroid, math.max(_currentZoom, 17.0));
            _showSnackBar('「${pg.name.isNotEmpty ? pg.name : pg.id}」（${layer.name}）に移動しました');
            return;
          }
        }
      }
    }
    _showSnackBar('「$query」に一致するデータが見つかりませんでした');
  }

  // ================================================================
  // 計測ツール
  // ================================================================

  /// 計測中のモードバーに表示するラベルを生成する
  String _buildMeasureLabel() {
    if (_measurePoints.length < 2) return 'タップして計測開始（距離・面積）';

    // 総距離
    double totalM = 0;
    for (int i = 0; i < _measurePoints.length - 1; i++) {
      totalM += _distance.distance(_measurePoints[i], _measurePoints[i + 1]);
    }
    final distLabel = totalM >= 1000
        ? '距離: ${(totalM / 1000).toStringAsFixed(3)} km'
        : '距離: ${totalM.toStringAsFixed(1)} m';

    if (_measurePoints.length < 3) return '$distLabel　（3点以上で面積も表示）';

    // 面積（Shoelace公式・球面近似）
    final areaM2 = _calcPolygonArea(_measurePoints);
    final areaLabel = areaM2 >= 10000
        ? '面積: ${(areaM2 / 10000).toStringAsFixed(2)} ha'
        : '面積: ${areaM2.toStringAsFixed(1)} m²';

    return '$distLabel　$areaLabel　（✕で計測リセット）';
  }

  /// Shoelace公式による近似面積（m²）
  double _calcPolygonArea(List<LatLng> pts) {
    if (pts.length < 3) return 0;
    const mPerDegLat = 111320.0;
    double area = 0;
    for (int i = 0; i < pts.length; i++) {
      final a = pts[i];
      final b = pts[(i + 1) % pts.length];
      final mPerDegLon = mPerDegLat * math.cos(a.latitude * math.pi / 180);
      final ax = a.longitude * mPerDegLon;
      final ay = a.latitude  * mPerDegLat;
      final bx = b.longitude * mPerDegLon;
      final by = b.latitude  * mPerDegLat;
      area += ax * by - bx * ay;
    }
    return area.abs() / 2;
  }

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

  /// 現在地ピンマーカー（📍型、ズーム連動サイズ）
  Marker _buildCurrentPositionMarker(LatLng position) {
    final fontSize   = _scaledStampFontSize();
    final markerSize = fontSize + 12;
    return Marker(
      point : position,
      width : markerSize,
      height: markerSize,
      child : Text(
        '📍',
        style: TextStyle(fontSize: fontSize),
        textAlign: TextAlign.center,
      ),
    );
  }

  // ================================================================
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
    // レイヤなし・未選択
    final label  = layer != null ? layer.name : 'レイヤ未選択';
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

        // 計測モード
        _roundFab(
          icon     : Icons.straighten,
          tooltip  : _isMeasuring ? '計測終了' : '距離・面積を計測',
          onTap    : _toggleMeasureMode,
          color    : _isMeasuring ? Colors.brown : Colors.white,
          iconColor: _isMeasuring ? Colors.white : Colors.brown,
          mini     : true,
        ),

        // 計測中：リセットボタン
        if (_isMeasuring && _measurePoints.isNotEmpty) ...[
          const SizedBox(height: 6),
          _roundFab(
            icon     : Icons.close,
            tooltip  : '計測リセット',
            onTap    : () => setState(() => _measurePoints.clear()),
            color    : Colors.brown.shade100,
            iconColor: Colors.brown,
            mini     : true,
          ),
        ],
        const SizedBox(height: 6),

        // 矢印スタンプモード（2点指定）
        _roundFab(
          icon: Icons.near_me,
          tooltip: '勾配矢印追加（2点指定）',
          onTap: _toggleStamp2PtMode,
          color: isStamp2Pt ? Colors.teal.shade700 : Colors.white,
          iconColor: isStamp2Pt ? Colors.white : Colors.teal.shade700,
          mini: true,
        ),
        const SizedBox(height: 6),

        // ポイント追加モード
        _roundFab(
          icon     : Icons.place,
          tooltip  : _isAddingPoint ? 'ポイント追加終了' : 'ポイント追加',
          onTap    : _toggleAddPointMode,
          color    : _isAddingPoint ? Colors.deepOrange : Colors.white,
          iconColor: _isAddingPoint ? Colors.white : Colors.deepOrange,
          mini     : true,
        ),
        const SizedBox(height: 6),

        // ポリゴン追加モード
        _roundFab(
          icon     : Icons.pentagon_outlined,
          tooltip  : _isAddingPolygon ? 'ポリゴン追加終了' : 'ポリゴン追加',
          onTap    : _toggleAddPolygonMode,
          color    : _isAddingPolygon ? Colors.purple : Colors.white,
          iconColor: _isAddingPolygon ? Colors.white : Colors.purple,
          mini     : true,
        ),

        // ポリゴン追加中：確定ボタン
        if (_isAddingPolygon && _newPolygonPoints.length >= 3) ...[
          const SizedBox(height: 6),
          _roundFab(
            icon     : Icons.check,
            tooltip  : 'ポリゴンを確定（${_newPolygonPoints.length}点）',
            onTap    : _confirmNewPolygon,
            color    : Colors.green,
            iconColor: Colors.white,
          ),
        ],
        const SizedBox(height: 6),

        // 複数選択モード
        _roundFab(
          icon     : Icons.checklist,
          tooltip  : _isMultiSelect ? '選択モード終了' : '複数選択',
          onTap    : _toggleMultiSelect,
          color    : _isMultiSelect ? Colors.indigo : Colors.white,
          iconColor: _isMultiSelect ? Colors.white  : Colors.indigo,
          mini     : true,
        ),

        // 複数選択中：一括編集ボタン
        if (_isMultiSelect && _selectedGutterIds.isNotEmpty) ...[
          const SizedBox(height: 6),
          _roundFab(
            icon     : Icons.edit_note,
            tooltip  : '一括編集（${_selectedGutterIds.length}件）',
            onTap    : _showBulkEditDialog,
            color    : Colors.indigo.shade700,
            iconColor: Colors.white,
          ),
        ],

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
  // ドロワー（レイヤ管理）
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
              const Text('レイヤ管理',
                  style: TextStyle(color: Colors.white, fontSize: 20, fontWeight: FontWeight.bold)),
              const SizedBox(height: 4),
              Text('${layers.length} レイヤ',
                  style: const TextStyle(color: Colors.white70, fontSize: 13)),
            ],
          ),
        ),
        Expanded(
          child: layers.isEmpty
              ? const Center(child: Text('レイヤがありません\n上部のフォルダアイコンから\nGeoJSONファイルを開いてください',
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
                          String countLabel;
                          if (layer.layerType == 'point') {
                            countLabel = '${layer.featurePoints.length} 点';
                          } else if (layer.layerType == 'polygon') {
                            countLabel = '${layer.featurePolygons.length} 面';
                          } else {
                            countLabel = '${layer.gutters.length} 本'
                              '${layer.categoryKey != null ? " ・ ${layer.categoryKey}" : ""}';
                          }
                          Color? bulkColor;
                          if (layer.layerType == 'line' && layer.categoryKey == null && layer.gutters.isNotEmpty) {
                            final firstColor = layer.gutters.first.color;
                            if (layer.gutters.every((g) => g.color.toARGB32() == firstColor.toARGB32())) {
                              bulkColor = firstColor;
                            }
                          } else if (layer.layerType == 'point' && layer.featurePoints.isNotEmpty) {
                            final firstColor = layer.featurePoints.first.color;
                            if (layer.featurePoints.every((p) => p.color.toARGB32() == firstColor.toARGB32())) {
                              bulkColor = firstColor;
                            }
                          }
                          return Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              // レイヤ種別アイコン
                              Icon(
                                layer.layerType == 'point'   ? Icons.place
                                  : layer.layerType == 'polygon' ? Icons.pentagon_outlined
                                  : Icons.polyline,
                                size: 13,
                                color: Colors.grey.shade600,
                              ),
                              const SizedBox(width: 4),
                              Text(countLabel, style: const TextStyle(fontSize: 12)),
                              if (bulkColor != null) ...[
                                const SizedBox(width: 6),
                                Container(
                                  width: 12, height: 12,
                                  decoration: BoxDecoration(
                                    color: bulkColor, shape: BoxShape.circle,
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
                          if (layer.layerType == 'line') ...[
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
                          ],
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
                                title  : const Text('レイヤ削除'),
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
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                leading: const Icon(Icons.add_circle_outline),
                title  : const Text('新しい空レイヤ作成'),
                onTap  : _createEmptyLayer,
              ),
              ListTile(
                leading: const Icon(Icons.delete_forever, color: Colors.red),
                title  : const Text('全データを消去', style: TextStyle(color: Colors.red)),
                onTap  : () => showDialog(
                  context: context,
                  builder: (dlgCtx) => AlertDialog(
                    title  : const Text('全データを消去'),
                    content: const Text('すべてのレイヤとデータを消去します。\nこの操作は元に戻せません。'),
                    actions: [
                      TextButton(
                        onPressed: () => Navigator.pop(dlgCtx),
                        child    : const Text('キャンセル'),
                      ),
                      FilledButton(
                        style    : FilledButton.styleFrom(backgroundColor: Colors.red),
                        onPressed: () async {
                          setState(() {
                            layers.clear();
                            selectedLayerIndex = null;
                            _undoStack.clear();
                            _redoStack.clear();
                          });
                          try {
                            web.window.localStorage.removeItem(_kStorageKey);
                          } catch (_) {}
                          try {
                            final prefs = await SharedPreferences.getInstance();
                            await prefs.remove(_kStorageKey);
                          } catch (_) {}
                          if (!dlgCtx.mounted) return;
                          Navigator.pop(dlgCtx);
                          Navigator.pop(dlgCtx); // ドロワーを閉じる
                          _showSnackBar('全データを消去しました');
                        },
                        child: const Text('消去する'),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    ),
  );
}