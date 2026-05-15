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

/// タイルURL一覧（currentTile をキーにして引く）
const _kTileUrls = {
  'osm': 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
  'gsi_photo':
      'https://cyberjapandata.gsi.go.jp/xyz/seamlessphoto/{z}/{x}/{y}.jpg',
};

/// ライン色パレット（編集フォームで選択）
const _kColorPalette = [
  Colors.blue, Colors.red, Colors.green, Colors.orange,
  Colors.purple, Colors.teal, Colors.brown, Colors.grey,
];

/// 断面形状の選択肢と表示ラベル
const _kShapeOptions = ['open', 'box', 'circle', 'other'];
const _kShapeLabels = {
  'open': '開渠', 'box': 'BOX', 'circle': '円形', 'other': 'その他',
};

/// 口径の選択肢
const _kDiameterOptions = [
  '300×300', '400×400', '500×500', '600×600',
  '700×700', '800×800', '900×900', '1000×1000',
  '300×400', '400×500', '500×600',
];

// ================================================================
// データモデル
// ================================================================

/// レイヤー: 複数のGutterをまとめる単位。カテゴリ色分けも管理する。
class GutterLayer {
  String id;
  String name;
  bool visible;
  List<Gutter> gutters;
  String? categoryKey;       // 色分けに使うプロパティキー（null = 個別色）
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
        'id': id,
        'name': name,
        'visible': visible,
        'gutters': gutters.map((g) => g.toJson()).toList(),
        'categoryKey': categoryKey,
        'categoryColors':
            categoryColors.map((k, v) => MapEntry(k, v.toARGB32())),
      };

  factory GutterLayer.fromJson(Map<String, dynamic> json) => GutterLayer(
        id: json['id']?.toString() ?? '',
        name: json['name']?.toString() ?? '',
        visible: json['visible'] ?? true,
        gutters: (json['gutters'] as List<dynamic>? ?? [])
            .map((g) => Gutter.fromJson(g as Map<String, dynamic>))
            .toList(),
        categoryKey: json['categoryKey']?.toString(),
        categoryColors: (json['categoryColors'] as Map<String, dynamic>? ?? {})
            .map((k, v) => MapEntry(k, Color(v as int))),
      );
}

/// 側溝1本分のデータ。座標列・表示スタイル・属性情報を保持する。
class Gutter {
  String id;
  String name;
  String shape;         // 断面形状（open / box / circle / other）
  String diameter;      // 口径（例: 300×300）
  String memo;          // 現地メモ
  bool flowReversed;    // 流向反転フラグ
  Color color;
  List<LatLng> points;
  Map<String, dynamic> properties; // GeoJSONの元プロパティをそのまま保持
  bool showArrow;       // 流向矢印を表示するか
  double arrowSize;     // 矢印サイズ（メートル）
  double strokeWidth;   // ラインの太さ（px）

  Gutter({
    required this.id,
    this.name = '',
    this.shape = 'open',
    this.diameter = '300×300',
    this.memo = '',
    this.flowReversed = false,
    required this.points,
    Color? color,
    Map<String, dynamic>? properties,
    this.showArrow = false,
    this.arrowSize = 12.0,
    this.strokeWidth = 7.5,
  })  : color = color ?? Colors.blue,
        properties = properties ?? {};

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'shape': shape,
        'diameter': diameter,
        'memo': memo,
        'flowReversed': flowReversed,
        'color': color.toARGB32(),
        'points': points.map((p) => [p.longitude, p.latitude]).toList(),
        'properties': properties,
        'showArrow': showArrow,
        'arrowSize': arrowSize,
        'strokeWidth': strokeWidth,
      };

  factory Gutter.fromJson(Map<String, dynamic> json) => Gutter(
        id: json['id']?.toString() ?? '',
        name: json['name']?.toString() ?? '',
        shape: json['shape']?.toString() ?? 'open',
        diameter: json['diameter']?.toString() ?? '300×300',
        memo: json['memo']?.toString() ?? '',
        flowReversed: json['flowReversed'] as bool? ?? false,
        color: Color(json['color'] as int? ?? Colors.blue.toARGB32()),
        points: (json['points'] as List<dynamic>)
            .map((e) => LatLng(
                (e[1] as num).toDouble(), (e[0] as num).toDouble()))
            .toList(),
        properties: Map<String, dynamic>.from(json['properties'] ?? {}),
        showArrow: json['showArrow'] as bool? ?? false,
        arrowSize: (json['arrowSize'] as num?)?.toDouble() ?? 12.0,
        strokeWidth: (json['strokeWidth'] as num?)?.toDouble() ?? 7.5,
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
  final _distance = const Distance();
  final _scaffoldKey = GlobalKey<ScaffoldState>();

  List<GutterLayer> layers = [];
  int? selectedLayerIndex;

  bool isAddingNew = false;
  List<LatLng> newPoints = [];
  bool isCutting = false;
  int _newGutterCounter = 1;

  String currentTile = 'osm';

  // initState内
@override
void initState() {
  super.initState();
  
  WidgetsBinding.instance.addPostFrameCallback((_) {
    final geojsonUrl = Uri.decodeComponent(
        Uri.base.queryParameters['geojson'] ?? '');
    
    if (geojsonUrl.isNotEmpty) {
      // URL指定がある場合はローカルデータをクリアしてURLの内容だけを表示
      _loadOnlyFromUrl(geojsonUrl);
    } else {
      _loadFromLocalStorage();
    }
  });
}

// 新規メソッド追加
Future<void> _loadOnlyFromUrl(String url) async {
  try {
    // ローカルストレージをクリア
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('layers_data');
    
    setState(() {
      layers.clear();
      selectedLayerIndex = null;
    });

    _showSnackBar('共有URLからデータを読み込み中...');
    final response = await http.get(Uri.parse(url));
    if (response.statusCode != 200) throw Exception('HTTP ${response.statusCode}');

    final data = jsonDecode(utf8.decode(response.bodyBytes));
    final gutters = _parseGeoJsonFeatures(
        data['features'] as List<dynamic>? ?? []);

    _addParsedLayer(gutters, '共有データ ${DateTime.now().toIso8601String().substring(0,10)}');
    
    _showAllGutters();
    _showSnackBar('${gutters.length}本の側溝を読み込みました（ローカルデータはクリア）');
  } catch (e) {
    _showSnackBar('URL読み込み失敗: $e');
    // 失敗したら通常のローカル読み込みにフォールバック
    _loadFromLocalStorage();
  }
}

  // ================================================================
  // ローカルストレージ
  // ================================================================
  Future<void> _saveToLocalStorage() async {
  try {
    final jsonString = jsonEncode(layers.map((l) => l.toJson()).toList());
    
    // Webでは dart:html の localStorage を直接使う（より安定）
    if (web.window.localStorage != null) {
      web.window.localStorage.setItem('layers_data', jsonString);
      debugPrint('✅ Web localStorage 保存完了');
    } else {
      // fallback
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('layers_data', jsonString);
    }
    
    debugPrint('保存完了: ${layers.length}レイヤー');
  } catch (e) {
    debugPrint('❌ 保存エラー: $e');
    _showSnackBar('保存エラー: $e');
  }
}

  Future<void> _loadFromLocalStorage() async {
  try {
    String? data;

    // Web localStorage優先
    if (web.window.localStorage != null) {
      data = web.window.localStorage.getItem('layers_data');
    }

    // fallbackでSharedPreferences
    if (data == null || data.isEmpty) {
      final prefs = await SharedPreferences.getInstance();
      data = prefs.getString('layers_data');
    }

    if (data == null || data.isEmpty) return;

    setState(() {
      layers = (jsonDecode(data!) as List<dynamic>)
          .map((j) => GutterLayer.fromJson(j as Map<String, dynamic>))
          .toList();
    });
    
    debugPrint('✅ 読み込み完了: ${layers.length}レイヤー');
  } catch (e) {
    debugPrint('❌ 読み込みエラー: $e');
  }
}

  // ================================================================
  // GeoJSON パース（共通ロジック）
  // ================================================================
  /// GeoJSONのfeatures配列からGutterリストを生成する共通処理。
List<Gutter> _parseGeoJsonFeatures(List<dynamic> features) {
  final gutters = <Gutter>[];
  for (final f in features) {
    final geometry = f['geometry'];
    if (geometry == null) continue;

    final List<dynamic> allCoords;
    if (geometry['type'] == 'MultiLineString') {
      allCoords = (geometry['coordinates'] as List)
          .expand((line) => line as List<dynamic>)
          .toList();
    } else if (geometry['type'] == 'LineString') {
      allCoords = geometry['coordinates'] as List<dynamic>;
    } else {
      continue;
    }

    final points = allCoords
        .map((c) => LatLng((c[1] as num).toDouble(), (c[0] as num).toDouble()))
        .toList();
    if (points.length < 2) continue;

    final props = f['properties'] ?? {};

    // ★★★ 優先順位を明確に（共有データ対応強化）★★★
    String shape = props['shape']?.toString() ?? 
                   props['断面形状']?.toString() ?? 'open';
    
    String diameter = props['diameter']?.toString() ?? 
                      props['口径']?.toString() ?? '300×300';
    
    String memo = props['memo']?.toString() ?? 
                  props['メモ']?.toString() ?? '';

    gutters.add(Gutter(
      id: props['id']?.toString() ?? 'SG-${DateTime.now().millisecondsSinceEpoch}',
      name: props['name']?.toString() ?? '',
      shape: shape,
      diameter: diameter,
      memo: memo,
      flowReversed: props['flowReversed'] as bool? ?? false,
      color: props['color'] != null 
          ? Color(props['color'] as int) 
          : Colors.blue,
      strokeWidth: (props['strokeWidth'] as num?)?.toDouble() ?? 7.5,
      showArrow: props['showArrow'] as bool? ?? false,
      arrowSize: (props['arrowSize'] as num?)?.toDouble() ?? 12.0,
      points: points,
      properties: Map<String, dynamic>.from(props),
    ));
  }
  return gutters;
}

  /// パース結果をレイヤーとして追加する共通処理
  void _addParsedLayer(List<Gutter> gutters, String name) {
    if (gutters.isEmpty) return;
    setState(() {
      layers.add(GutterLayer(
        id: DateTime.now().millisecondsSinceEpoch.toString(),
        name: name,
        gutters: gutters,
      ));
    });
    _showAllGutters();
  }

  // ================================================================
  // GeoJSON 読み込み（ファイル）
  // ================================================================

  Future<void> _loadGeoJSON() async {
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['geojson', 'json'],
        allowMultiple: false,
      );
      if (result == null || result.files.isEmpty) return;

      final file = result.files.first;
      final data = jsonDecode(utf8.decode(file.bytes!));
      final gutters =
          _parseGeoJsonFeatures(data['features'] as List<dynamic>? ?? []);

      if (gutters.isEmpty) {
        _showSnackBar('有効なラインがありませんでした');
        return;
      }

      final layerName = 'レイヤー ${layers.length + 1} - ${file.name}';
      _addParsedLayer(gutters, layerName);
      _showSnackBar('${gutters.length}件を「$layerName」に追加しました');

      // 読み込み後、Drawerを開いてレイヤーを確認しやすくする
      Future.delayed(const Duration(milliseconds: 300), () {
        if (mounted) _scaffoldKey.currentState?.openEndDrawer();
      });
    } catch (e) {
      debugPrint('読み込みエラー: $e');
      _showSnackBar('読み込みエラー: $e');
    }
  }

  // ================================================================
  // GeoJSON 読み込み（URL）
  // ================================================================

  Future<void> _loadGeoJSONFromUrl(String url) async {
    if (url.isEmpty) return;
    try {
      _showSnackBar('GeoJSONを読み込み中...');
      final response = await http.get(Uri.parse(url));
      if (response.statusCode != 200) {
        throw Exception('HTTP ${response.statusCode}');
      }

      final data = jsonDecode(utf8.decode(response.bodyBytes));
      final gutters =
          _parseGeoJsonFeatures(data['features'] as List<dynamic>? ?? []);

      _addParsedLayer(gutters, 'URL読み込み ${layers.length + 1}');
      _showSnackBar('${gutters.length}本のラインを読み込みました');
    } catch (e) {
      _showSnackBar('読み込み失敗: $e');
    }
  }

  // ================================================================
  // GeoJSON エクスポート（ダウンロード）
  // ================================================================

  void _exportGeoJSON() {
    try {
      final features = [
        for (final layer in layers)
          for (final g in layer.gutters)
            {
              'type': 'Feature',
              'geometry': {
                'type': 'LineString',
                'coordinates':
                    g.points.map((p) => [p.longitude, p.latitude]).toList(),
              },
              'properties': {
                'layer': layer.name,
                'id': g.id,
                'name': g.name,
                ...g.properties, // 元のGeoJSONプロパティをすべて保持
              },
            },
      ];

      if (features.isEmpty) {
        _showSnackBar('エクスポートするデータがありません');
        return;
      }

      final jsonString = const JsonEncoder.withIndent('  ').convert({
        'type': 'FeatureCollection',
        'features': features,
        'exported_at': DateTime.now().toIso8601String(),
      });

      final anchor = web.HTMLAnchorElement()
        ..href =
            'data:application/geo+json;base64,${base64Encode(utf8.encode(jsonString))}'
        ..download =
            'sideGutters_${DateTime.now().toIso8601String().substring(0, 10)}.geojson';
      web.document.body!.append(anchor);
      anchor.click();
      anchor.remove();

      _showSnackBar('${features.length}件をエクスポートしました');
    } catch (e) {
      debugPrint('Export Error: $e');
      _showSnackBar('エクスポートエラー: $e');
    }
  }

//================================================================
// GeoJSON アップロード（全レイヤー完全共有）
// ================================================================

Future<void> _uploadAllLayers() async {
  try {
    if (layers.isEmpty) {
      _showSnackBar('アップロードするデータがありません');
      return;
    }

    final List<Map<String, dynamic>> features = [];

    for (final layer in layers) {
      for (final g in layer.gutters) {
        features.add({
          'type': 'Feature',
          'geometry': {
            'type': 'LineString',
            'coordinates': g.points
                .map((p) => [p.longitude, p.latitude])
                .toList(),
          },
          'properties': {
            'layer': layer.name,
            'layerId': layer.id,
            'layerVisible': layer.visible,
            'id': g.id,
            'name': g.name,
            'shape': g.shape,
            'diameter': g.diameter,
            'memo': g.memo,
            'flowReversed': g.flowReversed,
            'color': g.color.toARGB32(),
            'strokeWidth': g.strokeWidth,
            'showArrow': g.showArrow,
            'arrowSize': g.arrowSize,
            // 既存の properties もマージ（念のため）
            ...g.properties,
          },
        });
      }
    }

    final response = await http.post(
      Uri.parse('/api/uploadGeoJson'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({
        'geojson': {
          'type': 'FeatureCollection',
          'features': features,
          'exported_at': DateTime.now().toIso8601String(),
          'layers_count': layers.length,
          'gutters_count': features.length,
        },
      }),
    );

    if (response.statusCode != 200) {
      String errorMsg = 'HTTP ${response.statusCode}';
      try {
        final errorData = jsonDecode(response.body);
        errorMsg += ': ${errorData.toString()}';
      } catch (_) {
        errorMsg += ': ${response.body}';
      }
      throw Exception(errorMsg);
    }

    final data = jsonDecode(response.body);
    final shareUrl = '${web.window.location.origin}/?geojson=${Uri.encodeComponent(data['rawUrl'] as String)}';

    await Clipboard.setData(ClipboardData(text: shareUrl));

    if (!mounted) return;

    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('共有URL生成完了'),
        content: SelectableText(shareUrl),
        actions: [
          TextButton(
            onPressed: () => Clipboard.setData(ClipboardData(text: shareUrl)),
            child: const Text('コピー'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('閉じる'),
          ),
        ],
      ),
    );

    _showSnackBar('${features.length}本を共有しました');
  } catch (e) {
    debugPrint('Upload Error: $e');
    _showSnackBar('アップロード失敗: $e');
  }
}

  // ================================================================
  // 共有URL生成
  // ================================================================

  void _generateShareUrl() => _showUrlInputDialog(
        title: 'GeoJSON共有URL生成',
        hint: 'https://raw.githubusercontent.com/...',
        actionLabel: '生成',
        onSubmit: (geojsonUrl) {
          final shareUrl =
              '${web.window.location.origin}/?geojson=${Uri.encodeComponent(geojsonUrl)}';
          Clipboard.setData(ClipboardData(text: shareUrl));
          _showSnackBar('共有URLをコピーしました');
          if (!context.mounted) return;
          showDialog(
            context: context,
            builder: (_) => AlertDialog(
              title: const Text('共有URL'),
              content: SelectableText(shareUrl),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text('閉じる'),
                ),
              ],
            ),
          );
        },
      );

  // ================================================================
  // モード切り替え
  // ================================================================

  void _toggleAddMode() => setState(() {
        isAddingNew = !isAddingNew;
        isCutting = false;
        newPoints.clear();
      });

  void _toggleCutMode() => setState(() {
        isCutting = !isCutting;
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
      // 選択中レイヤー内で最近傍のラインを探してタップ情報を表示
      final nearest = _findNearestGutterInLayer(point, layer);
      if (nearest != null) _showGutterInfo(nearest);
    }
  }

  // ================================================================
  // 切断機能
  // ================================================================

  /// タップ点に最も近いセグメントを分割し、2本のGutterに置き換える（30m以内のみ）
  void _cutLineAtPoint(LatLng tapPoint, GutterLayer layer) {
    double bestDist = double.infinity;
    int bestIdx = -1;
    int bestSeg = -1;
    LatLng? bestProj;

    for (int i = 0; i < layer.gutters.length; i++) {
      final pts = layer.gutters[i].points;
      if (pts.length < 2) continue;
      for (int j = 0; j < pts.length - 1; j++) {
        final proj = _projectOnSegment(tapPoint, pts[j], pts[j + 1]);
        final dist = _distance.distance(tapPoint, proj);
        if (dist < bestDist) {
          bestDist = dist;
          bestIdx = i;
          bestSeg = j;
          bestProj = proj;
        }
      }
    }

    if (bestIdx == -1 || bestDist >= 30 || bestProj == null) {
      _showSnackBar('ラインの近くをタップしてください');
      return;
    }
    
    final projPoint = bestProj;
    final g = layer.gutters[bestIdx];
    final pts = g.points;
    setState(() {
      layer.gutters
        ..removeAt(bestIdx)
        ..add(Gutter(
          id: '${g.id}-A',
          name: '${g.name}-A',
          points: [...pts.sublist(0, bestSeg + 1), projPoint],
          color: g.color,
          properties: Map.from(g.properties),
        ))
        ..add(Gutter(
          id: '${g.id}-B',
          name: '${g.name}-B',
          points: [projPoint, ...pts.sublist(bestSeg + 1)],
          color: g.color,
          properties: Map.from(g.properties),
        ));
    });

    _saveToLocalStorage();
    _showSnackBar('切断完了 (${bestDist.toStringAsFixed(1)}m)');
  }

  /// 点Pを線分AB上に正射影した最近傍点を返す（端点でクランプ）
  LatLng _projectOnSegment(LatLng p, LatLng a, LatLng b) {
    final dx = b.longitude - a.longitude;
    final dy = b.latitude - a.latitude;
    final len2 = dx * dx + dy * dy;
    if (len2 == 0) return a;
    final t = ((p.longitude - a.longitude) * dx +
            (p.latitude - a.latitude) * dy) /
        len2;
    final tc = t.clamp(0.0, 1.0);
    return LatLng(a.latitude + tc * dy, a.longitude + tc * dx);
  }

  /// 選択中レイヤー内で、タップ点から25m以内の最近傍Gutterを返す
  Gutter? _findNearestGutterInLayer(LatLng tapPoint, GutterLayer layer) {
    double bestDist = double.infinity;
    Gutter? nearest;
    for (final g in layer.gutters) {
      if (g.points.length < 2) continue;
      for (int j = 0; j < g.points.length - 1; j++) {
        final dist = _distance.distance(
            tapPoint,
            _projectOnSegment(tapPoint, g.points[j], g.points[j + 1]));
        if (dist < bestDist && dist < 25) {
          bestDist = dist;
          nearest = g;
        }
      }
    }
    return nearest;
  }

  // ================================================================
  // 新規Gutter追加
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
        title: const Text('新規側溝保存'),
        content: TextField(
            controller: ctrl,
            decoration: const InputDecoration(labelText: '側溝名')),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('キャンセル')),
          TextButton(
            onPressed: () {
              setState(() {
                layer.gutters.add(Gutter(
                  id: 'SG-00$_newGutterCounter',
                  name: ctrl.text,
                  points: List.from(newPoints),
                  properties: {},
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
  /// 属性情報の閲覧（シンプル版）
  void _showGutterInfo(Gutter g) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      useRootNavigator: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => Padding(
        padding: EdgeInsets.only(
          bottom: MediaQuery.of(context).viewInsets.bottom,
        ),
        child: SingleChildScrollView(
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
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
                        child: const Text('閉じる'),
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

/// メイン編集画面（現場で使いやすい構成）
  void _showEditForm(Gutter g) {
    if (_currentLayer == null) return;

    final memCtrl = TextEditingController(text: g.memo);
    final shapeCtrl = TextEditingController(text: g.shape);
    final diamCtrl = TextEditingController(text: g.diameter);
    final nameCtrl = TextEditingController(text: g.name);

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      useRootNavigator: true,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => StatefulBuilder(
        builder: (context, setS) => Padding(
          padding: EdgeInsets.only(
            bottom: MediaQuery.of(context).viewInsets.bottom,
          ),
          child: SingleChildScrollView(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 20, 20, 30),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('側溝編集 - ${g.id}',
                      style: Theme.of(context).textTheme.titleLarge),
                  const Divider(height: 24),

                  // 名称
                  TextField(
                    controller: nameCtrl,
                    decoration: const InputDecoration(labelText: '名称'),
                  ),
                  const SizedBox(height: 16),

                  // 形状
                  _buildAutocomplete(
                    label: '断面形状',
                    hint: '開渠 / BOX / 円形',
                    initial: g.shape,
                    options: _kShapeOptions,
                    display: (o) => _kShapeLabels[o] ?? o,
                    filter: (o, v) =>
                        o.toLowerCase().contains(v.toLowerCase()) ||
                        (_kShapeLabels[o] ?? '').contains(v),
                    ctrl: shapeCtrl,
                  ),
                  const SizedBox(height: 16),

                  // 口径
                  _buildAutocomplete(
                    label: '口径',
                    hint: '300×300 など',
                    initial: g.diameter,
                    options: _kDiameterOptions,
                    display: (o) => o,
                    filter: (o, v) => o.contains(v),
                    ctrl: diamCtrl,
                  ),
                  const SizedBox(height: 16),

                  // メモ
                  TextField(
                    controller: memCtrl,
                    maxLines: 3,
                    decoration: const InputDecoration(
                      labelText: 'メモ',
                      border: OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 20),

                  // 流向関連
                  Row(
                    children: [
                      Expanded(
                        child: SwitchListTile(
                          title: const Text('流向矢印を表示'),
                          value: g.showArrow,
                          onChanged: (v) => setS(() => g.showArrow = v),
                          contentPadding: EdgeInsets.zero,
                        ),
                      ),
                      TextButton.icon(
                        icon: const Icon(Icons.swap_horiz),
                        label: const Text('反転'),
                        onPressed: () async {
                            setState(() => g.points = g.points.reversed.toList());
                            await _saveToLocalStorage();
                            _showSnackBar('流向を反転しました');
                          },
                      ),
                    ],
                  ),

                  const Divider(height: 32),

                  // スタイル設定（少し下に）
                  const Text('スタイル設定', style: TextStyle(fontWeight: FontWeight.bold)),
                  const SizedBox(height: 12),

                  // 色
                  const Text('色'),
                  Wrap(
                    children: _kColorPalette.map((c) => GestureDetector(
                          onTap: () => setS(() => g.color = c),
                          child: Container(
                            width: 44,
                            height: 44,
                            margin: const EdgeInsets.all(5),
                            decoration: BoxDecoration(
                              color: c,
                              shape: BoxShape.circle,
                              border: Border.all(
                                color: g.color == c ? Colors.black : Colors.transparent,
                                width: 3,
                              ),
                            ),
                          ),
                        )).toList(),
                  ),
                  const SizedBox(height: 16),

                  // 太さ
                  const Text('線の太さ'),
                  Slider(
                    value: g.strokeWidth,
                    min: 3.0,
                    max: 15.0,
                    divisions: 24,
                    label: g.strokeWidth.toStringAsFixed(1),
                    onChanged: (v) => setS(() => g.strokeWidth = v),
                  ),

                  if (g.showArrow) ...[
                    const SizedBox(height: 12),
                    const Text('矢印サイズ'),
                    Slider(
                      value: g.arrowSize,
                      min: 5.0,
                      max: 20.0,
                      divisions: 30,
                      label: g.arrowSize.toStringAsFixed(1),
                      onChanged: (v) => setS(() => g.arrowSize = v),
                    ),
                  ],

                  const SizedBox(height: 40),

                  // 保存・キャンセル
                  Row(
                    children: [
                      Expanded(
                        child: TextButton(
                          onPressed: () => Navigator.pop(ctx),
                          child: const Text('キャンセル'),
                        ),
                      ),
                      Expanded(
                        child: ElevatedButton(
                        onPressed: () async {
                          setState(() {
                            g.name = nameCtrl.text;
                            g.shape = shapeCtrl.text.trim();
                            g.diameter = diamCtrl.text.trim();
                            g.memo = memCtrl.text.trim();
                          });
                          
                          await _saveToLocalStorage();   // 確実に待つ
                          
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

  /// オートコンプリート付きテキストフィールドを生成するファクトリメソッド
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
      initialValue: TextEditingValue(text: initial),
      optionsBuilder: (v) =>
          v.text.isEmpty ? options : options.where((o) => filter(o, v.text)),
      displayStringForOption: display,
      onSelected: (s) => ctrl.text = s,
      fieldViewBuilder: (context, fieldCtrl, focusNode, _) {
        ctrl.text = fieldCtrl.text;
        return TextFormField(
          controller: fieldCtrl,
          focusNode: focusNode,
          decoration: InputDecoration(
            labelText: label,
            border: const OutlineInputBorder(),
            hintText: hint,
          ),
        );
      },
    );
  }

  // ================================================================
  // カメラ・位置情報
  // ================================================================

  /// 表示中のすべてのGutterが収まるようにカメラをフィット
  void _showAllGutters() {
    final pts = layers
        .where((l) => l.visible)
        .expand((l) => l.gutters)
        .expand((g) => g.points)
        .toList();
    if (pts.isNotEmpty) {
      _mapController.fitCamera(CameraFit.bounds(
        bounds: LatLngBounds.fromPoints(pts),
        padding: const EdgeInsets.all(60),
      ));
    }
  }

  Future<void> _getCurrentLocation() async {
    try {
      final pos = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.high,
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
    final layer = layers[index];
    final ctrl = TextEditingController(text: layer.name);
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('レイヤー名変更'),
        content: TextField(controller: ctrl),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('キャンセル')),
          TextButton(
            onPressed: () {
              setState(() => layer.name = ctrl.text);
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
        id: DateTime.now().millisecondsSinceEpoch.toString(),
        name: '新規レイヤー ${layers.length + 1}',
        gutters: [],
      ));
    });
    _saveToLocalStorage();
  }

  // ================================================================
  // カテゴリ色分け
  // ================================================================

  /// カテゴリキーが設定されていればその値で色を決定、なければGutter個別色
  Color _getGutterColor(Gutter g, GutterLayer layer) {
    if (layer.categoryKey != null && layer.categoryColors.isNotEmpty) {
      final value = g.properties[layer.categoryKey!]?.toString() ?? '未分類';
      return layer.categoryColors[value] ?? Colors.grey;
    }
    return g.color;
  }

  /// 現在選択中のレイヤー（未選択の場合は先頭レイヤー）
  GutterLayer? get _currentLayer {
    if (layers.isEmpty) return null;
    if (selectedLayerIndex != null && selectedLayerIndex! < layers.length) {
      return layers[selectedLayerIndex!];
    }
    return layers.first;
  }

  List<String> _getAllPropertyKeys(GutterLayer layer) => ({
        for (final g in layer.gutters) ...g.properties.keys,
      }.toList()..sort());

  List<String> _getUniqueValues(GutterLayer layer, String? key) {
    if (key == null) return [];
    return ({
      for (final g in layer.gutters)
        g.properties[key]?.toString() ?? '未分類',
    }.toList()..sort());
  }

  Map<String, Color> _generateCategoryColors(GutterLayer layer, String key) {
    final values = _getUniqueValues(layer, key);
    final palette = [
      ...Colors.primaries, Colors.brown, Colors.grey, Colors.pink, Colors.cyan,
    ];
    return {
      for (int i = 0; i < values.length; i++)
        values[i]: palette[i % palette.length],
    };
  }

  void _showCategoryStylingDialog(int layerIndex) {
    final layer = layers[layerIndex];
    String? selectedKey = layer.categoryKey;
    Map<String, Color> tempColors = Map.from(layer.categoryColors);

    showDialog(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setS) {
          final uniqueValues = _getUniqueValues(layer, selectedKey);
          return AlertDialog(
            title: const Text('カテゴリによる色分け'),
            content: SizedBox(
              width: double.maxFinite,
              height: 480,
              child: Column(
                children: [
                  DropdownButton<String?>(
                    isExpanded: true,
                    hint: const Text('分類する属性を選択'),
                    value: selectedKey,
                    items: [
                      const DropdownMenuItem(
                          value: null, child: Text('無効（個別色を使う）')),
                      ..._getAllPropertyKeys(layer).map(
                          (k) => DropdownMenuItem(value: k, child: Text(k))),
                    ],
                    onChanged: (val) => setS(() {
                      selectedKey = val;
                      if (val != null) {
                        tempColors = _generateCategoryColors(layer, val);
                      }
                    }),
                  ),
                  const Divider(),
                  if (selectedKey != null)
                    Expanded(
                      child: ListView.builder(
                        itemCount: uniqueValues.length,
                        itemBuilder: (context, i) {
                          final value = uniqueValues[i];
                          return ListTile(
                            title: Text(value.isEmpty ? '（空）' : value),
                            trailing: GestureDetector(
                              onTap: () async {
                                final picked = await showDialog<Color>(
                                  context: context,
                                  builder: (dlg) => AlertDialog(
                                    title: Text('色を選択: $value'),
                                    content: Wrap(
                                      children: Colors.primaries
                                          .map((c) => GestureDetector(
                                                onTap: () =>
                                                    Navigator.pop(dlg, c),
                                                child: Container(
                                                  width: 48,
                                                  height: 48,
                                                  color: c,
                                                  margin:
                                                      const EdgeInsets.all(4),
                                                ),
                                              ))
                                          .toList(),
                                    ),
                                  ),
                                );
                                if (picked != null) {
                                  setS(() => tempColors[value] = picked);
                                }
                              },
                              child: Container(
                                width: 36,
                                height: 36,
                                decoration: BoxDecoration(
                                  color: tempColors[value] ?? Colors.grey,
                                  shape: BoxShape.circle,
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
                  child: const Text('キャンセル')),
              TextButton(
                onPressed: () {
                  setState(() {
                    layer.categoryKey = selectedKey;
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
  // 流向矢印（Polygon）
  // ================================================================

  /// showArrow=true のGutterの終点に三角形ポリゴンを生成する
  List<Polygon> _createFlowArrowPolygons() => [
        for (final layer in layers)
          if (layer.visible)
            for (final g in layer.gutters)
              if (g.showArrow && g.points.length >= 2)
                Polygon(
                  points: _arrowheadPoints(
                    g.points[g.points.length - 2],
                    g.points.last,
                    sizeMeters: g.arrowSize,
                  ),
                  color: _getGutterColor(g, layer),
                  borderColor: Colors.white,
                  borderStrokeWidth: 1.5,
                ),
      ];

  /// ラインの [from→to] 方向に合わせた矢頭の3頂点を返す。
  /// 先端はto（ライン終点）に完全一致。開き角は30度（半角15度）。
  List<LatLng> _arrowheadPoints(LatLng from, LatLng to,
      {double sizeMeters = 12.0}) {
    final dy = to.latitude - from.latitude;
    final dx = to.longitude - from.longitude;

    const mPerDegLat = 111320.0;
    final mPerDegLon = mPerDegLat * math.cos(to.latitude * math.pi / 180);

    final vecY = dy * mPerDegLat;
    final vecX = dx * mPerDegLon;
    final len = math.sqrt(vecX * vecX + vecY * vecY);
    if (len < 0.000001) return [to, to, to];

    // 進行方向の単位ベクトル (ux, uy) と垂直単位ベクトル (vx, vy)
    final ux = vecX / len;
    final uy = vecY / len;
    final vx = -uy;
    final vy = ux;
    final halfWidth = sizeMeters * math.tan(15.0 * math.pi / 180);

    // 底辺の中心: 先端から進行方向の逆にsizeMeters
    final bx = -ux * sizeMeters;
    final by = -uy * sizeMeters;

    return [
      to,
      LatLng(to.latitude + (by - vy * halfWidth) / mPerDegLat,
          to.longitude + (bx - vx * halfWidth) / mPerDegLon),
      LatLng(to.latitude + (by + vy * halfWidth) / mPerDegLat,
          to.longitude + (bx + vx * halfWidth) / mPerDegLon),
    ];
  }

  // ================================================================
  // ユーティリティ
  // ================================================================

  /// mounted チェック付きSnackBar表示
  void _showSnackBar(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  /// URL入力ダイアログ（URL読み込み・共有URL生成で共用）
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
        title: Text(title),
        content: TextField(
          controller: ctrl,
          decoration: InputDecoration(hintText: hint),
          maxLines: 3,
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('キャンセル')),
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
  // UI（buildを役割ごとのメソッドに分割して見通しを良くする）
  // ================================================================

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      key: _scaffoldKey,
      appBar: _buildAppBar(),
      body: _buildMap(),
      endDrawer: _buildDrawer(),
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
            icon: const Icon(Icons.layers),
            onSelected: (v) => setState(() => currentTile = v),
            itemBuilder: (_) => const [
              PopupMenuItem(value: 'osm', child: Text('OpenStreetMap')),
              PopupMenuItem(value: 'gsi_photo', child: Text('航空写真')),
            ],
          ),
          IconButton(
            icon: const Icon(Icons.menu),
            onPressed: () => _scaffoldKey.currentState?.openEndDrawer(),
          ),
        ],
      );

  Widget _buildMap() => FlutterMap(
        mapController: _mapController,
        options: MapOptions(
          initialCenter: const LatLng(36.555, 139.882),
          initialZoom: 17.0,
          onTap: _addPoint,
        ),
        children: [
          TileLayer(
            urlTemplate: _kTileUrls[currentTile] ?? _kTileUrls['osm']!,
            userAgentPackageName: 'com.example.sideGutter_map',
          ),
          // 各レイヤーのポリライン
          ...layers.where((l) => l.visible).map((layer) => PolylineLayer(
                polylines: layer.gutters
                    .map((g) => Polyline(
                          points: g.points,
                          color: _getGutterColor(g, layer),
                          strokeWidth: g.strokeWidth,
                          borderStrokeWidth: 2.5,
                          borderColor: Colors.white,
                        ))
                    .toList(),
              )),
          // 新規追加中のプレビューライン
          if (isAddingNew && newPoints.isNotEmpty)
            PolylineLayer(
              polylines: [
                Polyline(
                    points: newPoints, color: Colors.orange, strokeWidth: 7.5),
              ],
            ),
          // 流向矢印
          ..._createFlowArrowPolygons()
              .map((p) => PolygonLayer(polygons: [p], polygonCulling: false)),
        ],
      );

  /// レイヤー管理ドロワー
  Widget _buildDrawer() => Drawer(
        child: Column(
          children: [
            const DrawerHeader(
              decoration: BoxDecoration(color: Colors.blue),
              child: Center(
                child: Text('レイヤー管理',
                    style: TextStyle(color: Colors.white, fontSize: 20)),
              ),
            ),
            Expanded(
              child: ListView.builder(
                itemCount: layers.length,
                itemBuilder: (context, index) {
                  final layer = layers[index];
                  return ListTile(
                    leading: Checkbox(
                      value: layer.visible,
                      onChanged: (v) => setState(() => layer.visible = v!),
                    ),
                    title: Text(layer.name),
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
                      children: [
                        IconButton(
                          icon: const Icon(Icons.palette),
                          tooltip: 'カテゴリ色分け設定',
                          onPressed: () => _showCategoryStylingDialog(index),
                        ),
                        IconButton(
                          icon: const Icon(Icons.edit),
                          tooltip: 'レイヤー名変更',
                          onPressed: () => _renameLayer(index),
                        ),
                        IconButton(
                          icon: const Icon(Icons.delete),
                          tooltip: 'レイヤー削除',
                          onPressed: () => showDialog(
                            context: context,
                            builder: (_) => AlertDialog(
                              title: const Text('レイヤー削除'),
                              content: Text('「${layer.name}」を削除しますか？'),
                              actions: [
                                TextButton(
                                  onPressed: () => Navigator.pop(context),
                                  child: const Text('キャンセル'),
                                ),
                                TextButton(
                                  onPressed: () {
                                    setState(() {
                                      layers.removeAt(index);
                                      // 削除後に選択インデックスが範囲外になる場合に補正
                                      if (selectedLayerIndex != null &&
                                          selectedLayerIndex! >= layers.length) {
                                        selectedLayerIndex = layers.isEmpty
                                            ? null
                                            : layers.length - 1;
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
              title: const Text('新しい空レイヤー作成'),
              onTap: _createEmptyLayer,
            ),
          ],
        ),
      );

  /// FABを1つ生成するヘルパー
  FloatingActionButton _fab({
    required String tag,
    required IconData icon,
    required VoidCallback onPressed,
    Color? color,
    bool mini = false,
  }) =>
      FloatingActionButton(
        heroTag: tag,
        mini: mini,
        backgroundColor: color,
        onPressed: onPressed,
        child: Icon(icon),
      );

  /// フローティングアクションボタン群
  /// FAB間には一定のスペース(8px)を挿入する
  Widget _buildFab() {
    final fabs = <Widget>[
      _fab(tag: 'all', icon: Icons.fullscreen, onPressed: _showAllGutters, mini: true),
      if (isAddingNew)
        _fab(tag: 'save', icon: Icons.save, onPressed: _saveNewGutter),
      _fab(
        tag: 'cut',
        icon: Icons.content_cut,
        onPressed: _toggleCutMode,
        color: isCutting ? Colors.purple : null,
      ),
      _fab(
        tag: 'add',
        icon: isAddingNew ? Icons.close : Icons.add,
        onPressed: _toggleAddMode,
        color: isAddingNew ? Colors.red : Colors.green,
      ),
      _fab(tag: 'location', icon: Icons.my_location, onPressed: _getCurrentLocation),
      _fab(tag: 'load', icon: Icons.upload_file, onPressed: _loadGeoJSON),
      _fab(tag: 'export', icon: Icons.download, onPressed: _exportGeoJSON),
      _fab(
        tag: 'url_load',
        icon: Icons.link,
        onPressed: () => _showUrlInputDialog(
          title: 'GeoJSON URLから読み込み',
          hint: 'https://gist.githubusercontent.com/...',
          actionLabel: '読み込み',
          onSubmit: _loadGeoJSONFromUrl,
        ),
      ),
      _fab(tag: 'share_url', icon: Icons.share, onPressed: _generateShareUrl),
      _fab(tag: 'upload', icon: Icons.cloud_upload, onPressed: _uploadAllLayers),
    ];

    // FAB間に8pxのスペースを挿入
    final spaced = <Widget>[];
    for (int i = 0; i < fabs.length; i++) {
      spaced.add(fabs[i]);
      if (i < fabs.length - 1) spaced.add(const SizedBox(height: 8));
    }

    return Column(mainAxisAlignment: MainAxisAlignment.end, children: spaced);
  }
}