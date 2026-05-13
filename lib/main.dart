import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart';
import 'package:file_picker/file_picker.dart';
import 'dart:convert';
import 'package:web/web.dart' as web;
import 'package:shared_preferences/shared_preferences.dart';
import 'dart:math' as math;
import 'package:http/http.dart' as http;   // URL読み込み用

void main() {
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: '側溝踏査マップ',
      home: const MapPage(),
      debugShowCheckedModeBanner: false,
    );
  }
}

// ==================== GutterLayer / Gutter ====================
class GutterLayer {
  String id;
  String name;
  bool visible;
  List<Gutter> gutters;
  String? categoryKey;
  Map<String, Color> categoryColors = {};

  GutterLayer({
    required this.id,
    required this.name,
    this.visible = true,
    required this.gutters,
    this.categoryKey,
    Map<String, Color>? categoryColors,
  }) : categoryColors = categoryColors ?? {};

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'name': name,
      'visible': visible,
      'gutters': gutters.map((g) => g.toJson()).toList(),
      'categoryKey': categoryKey,
      'categoryColors': categoryColors.map((k, v) => MapEntry(k, v.toARGB32())),
    };
  }

  factory GutterLayer.fromJson(Map<String, dynamic> json) {
    final guttersJson = json['gutters'] as List<dynamic>? ?? [];
    final gutters = guttersJson.map((g) => Gutter.fromJson(g as Map<String, dynamic>)).toList();

    final catColors = <String, Color>{};
    if (json['categoryColors'] != null) {
      (json['categoryColors'] as Map<String, dynamic>).forEach((k, v) {
        catColors[k] = Color(v as int);
      });
    }

    return GutterLayer(
      id: json['id']?.toString() ?? '',
      name: json['name']?.toString() ?? '',
      visible: json['visible'] ?? true,
      gutters: gutters,
      categoryKey: json['categoryKey']?.toString(),
      categoryColors: catColors,
    );
  }
}

class Gutter {
  String id;
  String name;
  Color color;
  List<LatLng> points;
  Map<String, dynamic> properties;
  bool showArrow;
  double arrowSize;
  double strokeWidth;

  Gutter({
    required this.id,
    this.name = '',
    required this.points,
    Color? color,
    Map<String, dynamic>? properties,
    this.showArrow = false,
    this.arrowSize = 12.0,
    this.strokeWidth = 7.5,
  }) : color = color ?? Colors.blue,
       properties = properties ?? {};

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'color': color.toARGB32(),
        'points': points.map((p) => [p.longitude, p.latitude]).toList(),
        'properties': properties,
        'showArrow': showArrow,
        'arrowSize': arrowSize,
        'strokeWidth': strokeWidth,
      };

  factory Gutter.fromJson(Map<String, dynamic> json) {
    return Gutter(
      id: json['id']?.toString() ?? '',
      name: json['name']?.toString() ?? '',
      color: Color(json['color'] as int? ?? Colors.blue.toARGB32()),
      points: (json['points'] as List<dynamic>)
          .map((e) => LatLng((e[1] as num).toDouble(), (e[0] as num).toDouble()))
          .toList(),
      properties: Map<String, dynamic>.from(json['properties'] ?? {}),
      showArrow: json['showArrow'] as bool? ?? false,
      arrowSize: (json['arrowSize'] as num?)?.toDouble() ?? 12.0,
      strokeWidth: (json['strokeWidth'] as num?)?.toDouble() ?? 7.5,
    );
  }
}

class MapPage extends StatefulWidget {
  const MapPage({super.key});
  @override
  State<MapPage> createState() => _MapPageState();
}

class _MapPageState extends State<MapPage> {
  final MapController mapController = MapController();
  final Distance distanceCalculator = const Distance();
  final GlobalKey<ScaffoldState> _scaffoldKey = GlobalKey<ScaffoldState>();

  List<GutterLayer> layers = [];
  int? selectedLayerIndex;

  bool isAddingNew = false;
  List<LatLng> newPoints = [];
  bool isCutting = false;
  int newGutterCounter = 1;

  String currentTile = 'osm';

  @override
  void initState() {
    super.initState();
    _loadFromLocalStorage();

    // URLパラメータから自動読み込み
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final uri = Uri.parse(web.window.location.href);
      final geojsonUrl = uri.queryParameters['geojson'];
      if (geojsonUrl != null && geojsonUrl.isNotEmpty) {
        _loadGeoJSONFromUrl(geojsonUrl);
      }
    });
  }

  // ==================== URLからGeoJSON読み込み（新規追加） ====================
  Future<void> _loadGeoJSONFromUrl(String url) async {
    try {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('GeoJSONを読み込み中...')),
        );
      }

      final response = await http.get(Uri.parse(url));
      if (response.statusCode != 200) {
        throw Exception('HTTP ${response.statusCode}');
      }

      final data = jsonDecode(utf8.decode(response.bodyBytes));
      final features = data['features'] as List<dynamic>? ?? [];

      final List<Gutter> loadedGutters = [];

      for (var f in features) {
        final geometry = f['geometry'];
        if (geometry == null) continue;

        List<dynamic> allCoords = [];
        if (geometry['type'] == 'MultiLineString') {
          for (var line in geometry['coordinates'] as List) {
            allCoords.addAll(line as List<dynamic>);
          }
        } else if (geometry['type'] == 'LineString') {
          allCoords = geometry['coordinates'] as List<dynamic>;
        } else {
          continue;
        }

        final points = allCoords
            .map((coord) => LatLng((coord[1] as num).toDouble(), (coord[0] as num).toDouble()))
            .toList();

        if (points.length < 2) continue;

        final props = f['properties'] ?? {};
        loadedGutters.add(Gutter(
          id: props['id']?.toString() ?? 'SG-${DateTime.now().millisecondsSinceEpoch}',
          name: props['name']?.toString() ?? '',
          points: points,
          color: props['color'] != null ? Color(props['color'] as int) : Colors.blue,
          strokeWidth: (props['strokeWidth'] as num?)?.toDouble() ?? 7.5,
          showArrow: props['showArrow'] as bool? ?? false,
          properties: Map<String, dynamic>.from(props),
        ));
      }

      if (loadedGutters.isEmpty) return;

      setState(() {
        layers.add(GutterLayer(
          id: DateTime.now().millisecondsSinceEpoch.toString(),
          name: "URL読み込み ${layers.length + 1}",
          gutters: loadedGutters,
        ));
      });

      _showAllGutters();

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('${loadedGutters.length}本のラインを読み込みました')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('読み込み失敗: $e')),
        );
      }
    }
  }

  // ==================== 以下はあなたの元のコードをそのまま使用 ====================
  String getTileUrl() {
    switch (currentTile) {
      case 'gsi_photo':
        return 'https://cyberjapandata.gsi.go.jp/xyz/seamlessphoto/{z}/{x}/{y}.jpg';
      default:
        return 'https://tile.openstreetmap.org/{z}/{x}/{y}.png';
    }
  }

  Future<void> _saveToLocalStorage() async {
    final prefs = await SharedPreferences.getInstance();
    final layersData = layers.map((layer) => layer.toJson()).toList();
    await prefs.setString('layers_data', jsonEncode(layersData));
  }

  Future<void> _loadFromLocalStorage() async {
    final prefs = await SharedPreferences.getInstance();
    final String? data = prefs.getString('layers_data');

    if (data != null && data.isNotEmpty) {
      try {
        final List<dynamic> layersJson = jsonDecode(data);
        setState(() {
          layers.clear();
          for (var layerJson in layersJson) {
            layers.add(GutterLayer.fromJson(layerJson as Map<String, dynamic>));
          }
        });
      } catch (e) {
        debugPrint('レイヤー読み込みエラー: $e');
      }
    }
  }

        // ==================== GeoJSON 読み込み ====================
  Future<void> _loadGeoJSON() async {
    try {
      final FilePickerResult? result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['geojson', 'json'],
        allowMultiple: false,
      );

      if (result == null || result.files.isEmpty) return;

      final PlatformFile file = result.files.first;
      final jsonString = utf8.decode(file.bytes!);
      final data = jsonDecode(jsonString);
      final features = data['features'] as List<dynamic>? ?? [];

      final List<Gutter> loadedGutters = [];

      for (var f in features) {
        final geometry = f['geometry'];
        if (geometry == null) continue;

        List<dynamic> allCoords = [];
        if (geometry['type'] == 'MultiLineString') {
          for (var line in geometry['coordinates'] as List) {
            allCoords.addAll(line as List<dynamic>);
          }
        } else if (geometry['type'] == 'LineString') {
          allCoords = geometry['coordinates'] as List<dynamic>;
        } else {
          continue;
        }

        final points = allCoords
            .map((coord) => LatLng((coord[1] as num).toDouble(), (coord[0] as num).toDouble()))
            .toList();

        if (points.length < 2) continue;

        final props = f['properties'] ?? {};
        loadedGutters.add(Gutter(
          id: props['id']?.toString() ?? 
              props['ID']?.toString() ?? 
              'SG-${DateTime.now().millisecondsSinceEpoch}',
          name: props['name']?.toString() ?? 
                props['名称']?.toString() ?? 
                props['Name']?.toString() ?? '',
          points: points,
          properties: Map<String, dynamic>.from(props),
        ));
      }

      if (loadedGutters.isEmpty) {
        if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('有効なラインがありませんでした')));
        }
        return;
      }

      final layerName = "レイヤー ${layers.length + 1} - ${file.name}";

      setState(() {
        layers.add(GutterLayer(
          id: DateTime.now().millisecondsSinceEpoch.toString(),
          name: layerName,
          gutters: loadedGutters,
        ));
      });

      // 自動でDrawerを開く（確認しやすくする）
      Future.delayed(const Duration(milliseconds: 300), () {
        if (mounted) {                    // ← 追加
          Scaffold.of(context).openEndDrawer();
        }
      });

      if (mounted) {                      // ← 追加
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('${loadedGutters.length}件を「$layerName」に追加しました')),
        );
      }

      _showAllGutters();
    } 
    catch (e) {
      print('読み込みエラー: $e');
        if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('読み込みエラー: $e')));
        }
    }
  }

  void _exportGeoJSON() {
    try {
      final List<Map<String, dynamic>> allFeatures = [];

      for (final layer in layers) {
        for (final g in layer.gutters) {
          allFeatures.add({
            "type": "Feature",
            "geometry": {
              "type": "LineString",
              "coordinates": g.points.map((p) => [p.longitude, p.latitude]).toList(),
            },
            "properties": {
              "layer": layer.name,
              "id": g.id,
              "name": g.name,
              ...g.properties,        // GeoJSONに元々あった全フィールドを展開
            },
          });
        }
      }

      if (allFeatures.isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('エクスポートするデータがありません')),
        );
        return;
      }

      final geoJson = {
        "type": "FeatureCollection",
        "features": allFeatures,
        "exported_at": DateTime.now().toIso8601String(),
      };

      final jsonString = const JsonEncoder.withIndent('  ').convert(geoJson);

      final bytes = utf8.encode(jsonString);
      final base64String = base64Encode(bytes);
      final dataUrl = 'data:application/geo+json;base64,$base64String';

      final anchor = web.HTMLAnchorElement()
        ..href = dataUrl
        ..download = "sideGutters_${DateTime.now().toIso8601String().substring(0, 10)}.geojson";

      web.document.body!.append(anchor);
      anchor.click();
      anchor.remove();

      if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('${allFeatures.length}件をエクスポートしました')),
      );
      }
    } catch (e) {
      print('Export Error: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('エクスポートエラー: $e')));
      }
    }
  }

  // ==================== モード切り替え ====================
  void _toggleAddMode() {
    setState(() {
      isAddingNew = !isAddingNew;
      isCutting = false;
      newPoints.clear();
    });
  }

  void _toggleCutMode() {
    setState(() {
      isCutting = !isCutting;
      isAddingNew = false;
    });
  }

    void _addPoint(TapPosition tapPosition, LatLng point) {
    final currentLayer = _currentLayer;
    if (currentLayer == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('レイヤーがありません。先にGeoJSONを読み込んでください。')),
      );
      return;
    }

    if (isAddingNew) {
      setState(() => newPoints.add(point));
    } else if (isCutting) {
      _cutLineAtPoint(point, currentLayer);   // 修正
    } else {
      // 現在選択中のレイヤー内のラインだけを対象に検索
      final nearest = _findNearestGutterInLayer(point, currentLayer);
      if (nearest != null) {
        _showGutterInfo(nearest);
      }
    }
  }

  // ==================== 切断機能 ====================
  void _cutLineAtPoint(LatLng tapPoint, GutterLayer layer) {
    double bestDistance = double.infinity;
    int bestGutterIndex = -1;
    int bestSegmentIndex = -1;
    LatLng? bestSplitPoint;

    for (int i = 0; i < layer.gutters.length; i++) {
      final gutter = layer.gutters[i];
      final points = gutter.points;
      if (points.length < 2) continue;

      for (int j = 0; j < points.length - 1; j++) {
        final p1 = points[j];
        final p2 = points[j + 1];
        final projection = _projectPointOnSegment(tapPoint, p1, p2);
        final dist = distanceCalculator.distance(tapPoint, projection);

        if (dist < bestDistance) {
          bestDistance = dist;
          bestGutterIndex = i;
          bestSegmentIndex = j;
          bestSplitPoint = projection;
        }
      }
    }

    if (bestGutterIndex != -1 && bestDistance < 30 && bestSplitPoint != null) {
      final gutter = layer.gutters[bestGutterIndex];
      final points = gutter.points;
      final splitIdx = bestSegmentIndex + 1;

      final partA = [...points.sublist(0, splitIdx), bestSplitPoint];
      final partB = [bestSplitPoint, ...points.sublist(splitIdx)];

      setState(() {
        layer.gutters.removeAt(bestGutterIndex);

        layer.gutters.add(Gutter(
          id: '${gutter.id}-A',
          name: '${gutter.name}-A',
          points: partA,
          color: gutter.color,
          properties: Map.from(gutter.properties),
        ));

        layer.gutters.add(Gutter(
          id: '${gutter.id}-B',
          name: '${gutter.name}-B',
          points: partB,
          color: gutter.color,
          properties: Map.from(gutter.properties),
        ));
      });

      _saveToLocalStorage();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('切断完了 (${bestDistance.toStringAsFixed(1)}m)')),
      );
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('ラインの近くをタップしてください')),
      );
    }
  }

  LatLng _projectPointOnSegment(LatLng p, LatLng a, LatLng b) {
    final dx = b.longitude - a.longitude;
    final dy = b.latitude - a.latitude;
    final len2 = dx * dx + dy * dy;
    if (len2 == 0) return a;
    var t = ((p.longitude - a.longitude) * dx + (p.latitude - a.latitude) * dy) / len2;
    t = t.clamp(0.0, 1.0);
    return LatLng(a.latitude + t * dy, a.longitude + t * dx);
  }

    Gutter? _findNearestGutterInLayer(LatLng tapPoint, GutterLayer layer) {
    double bestDistance = double.infinity;
    Gutter? nearestGutter;

    for (final gutter in layer.gutters) {
      if (gutter.points.length < 2) continue;
      for (int j = 0; j < gutter.points.length - 1; j++) {
        final p1 = gutter.points[j];
        final p2 = gutter.points[j + 1];
        final projection = _projectPointOnSegment(tapPoint, p1, p2);
        final dist = distanceCalculator.distance(tapPoint, projection);

        if (dist < bestDistance && dist < 25) {
          bestDistance = dist;
          nearestGutter = gutter;
        }
      }
    }
    return nearestGutter;
  }

    // ==================== 新規追加 ====================
  void _saveNewGutter() {
    if (newPoints.length < 2) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('2点以上タップしてください')));
      return;
    }

    final currentLayer = _currentLayer;
    if (currentLayer == null) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('レイヤーが選択されていません')));
      return;
    }

    final nameController = TextEditingController(text: '側溝 SG-00$newGutterCounter');

    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('新規側溝保存'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(controller: nameController, decoration: const InputDecoration(labelText: '側溝名')),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('キャンセル')),
          TextButton(
            onPressed: () {
              setState(() {
                currentLayer.gutters.add(Gutter(
                  id: 'SG-00$newGutterCounter',
                  name: nameController.text,
                  points: List.from(newPoints),
                  properties: {},
                ));
                newGutterCounter++;
                newPoints.clear();
                isAddingNew = false;
              });

              _saveToLocalStorage();
              if (mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text('「${currentLayer.name}」に追加しました')),
                );
              }
              Navigator.pop(context);
            },
            child: const Text('保存'),
          ),
        ],
      ),
    );
  }

  // ==================== 情報表示・編集 ====================
  void _showGutterInfo(Gutter gutter) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(gutter.name.isNotEmpty ? gutter.name : '属性情報'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('ID: ${gutter.id}'),
              const Divider(),
              ...gutter.properties.entries.map((e) => 
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: Text('${e.key}: ${e.value}'),
                )
              )
            ],
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('閉じる')),
          TextButton(onPressed: () { Navigator.pop(context); _showEditForm(gutter); }, child: const Text('編集')),
          TextButton(onPressed: () { Navigator.pop(context); _confirmDelete(gutter); }, child: const Text('削除', style: TextStyle(color: Colors.red))),
        ],
      ),
    );
  }

    void _showEditForm(Gutter gutter) {
    final currentLayer = _currentLayer;
    if (currentLayer == null) return;

    // 編集用のコントローラーを作成
    final controllers = <String, TextEditingController>{};
    gutter.properties.forEach((key, value) {
      controllers[key] = TextEditingController(text: value?.toString() ?? '');
    });

    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: Text(gutter.name.isNotEmpty ? gutter.name : '属性編集'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // 名称（特別扱い）
                TextField(
                  controller: TextEditingController(text: gutter.name),
                  decoration: const InputDecoration(labelText: '名称'),
                  onChanged: (v) => gutter.name = v,
                ),
                const SizedBox(height: 12),
                
                // GeoJSONの全フィールドを動的に表示
                ...controllers.entries.map((entry) {
                  return Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: TextField(
                      controller: entry.value,
                      decoration: InputDecoration(labelText: entry.key),
                    ),
                  );
                }),
                const SizedBox(height: 12),
                const Text('ライン色'),
                Wrap(
                  children: [
                    Colors.blue, Colors.red, Colors.green, Colors.orange,
                    Colors.purple, Colors.teal, Colors.brown, Colors.grey
                  ].map((c) => GestureDetector(
                        onTap: () => setDialogState(() => gutter.color = c),
                        child: Container(
                          width: 40, height: 40,
                          margin: const EdgeInsets.all(6),
                          decoration: BoxDecoration(
                            color: c,
                            shape: BoxShape.circle,
                            border: Border.all(
                              color: gutter.color == c ? Colors.black : Colors.transparent,
                              width: 3,
                            ),
                          ),
                        ),
                      )).toList(),
                ),
                                const SizedBox(height: 16),
                CheckboxListTile(
                  title: const Text('終点に流向矢印を表示'),
                  value: gutter.showArrow,
                  onChanged: (val) {
                    setDialogState(() => gutter.showArrow = val ?? false);
                  },
                  controlAffinity: ListTileControlAffinity.leading,
                ),
                const SizedBox(height: 8),
                if (gutter.showArrow) ...[
                  const Text('矢印サイズ'),
                  Slider(
                    value: gutter.arrowSize,
                    min: 5.0,
                    max: 20.0,
                    divisions: 30,
                    label: gutter.arrowSize.toStringAsFixed(1),
                    onChanged: (val) {
                      setDialogState(() => gutter.arrowSize = val);
                    },
                  ),
                  Text('現在のサイズ: ${gutter.arrowSize.toStringAsFixed(1)}'),
                ],

                const SizedBox(height: 16),
                const Text('ラインの太さ'),
                Slider(
                  value: gutter.strokeWidth,
                  min: 3.0,
                  max: 15.0,
                  divisions: 24,
                  label: gutter.strokeWidth.toStringAsFixed(1),
                  onChanged: (val) {
                    setDialogState(() => gutter.strokeWidth = val);
                  },
                ),
                Text('現在の太さ: ${gutter.strokeWidth.toStringAsFixed(1)}'),
              ],
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('キャンセル')),
              // 流向反転ボタン
              TextButton.icon(
                icon: const Icon(Icons.swap_horiz),
                label: const Text('流向反転'),
                onPressed: () {
                  setState(() {
                    gutter.points = gutter.points.reversed.toList();
                  });
                  _saveToLocalStorage();
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('流向を反転しました')),
                  );
                },
              ),
              
            TextButton(
              onPressed: () {
                // 編集した値をpropertiesに戻す
                controllers.forEach((key, ctrl) {
                  gutter.properties[key] = ctrl.text;
                });

                setState(() {});
                _saveToLocalStorage();
                Navigator.pop(ctx);
                if (mounted) {
                ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('保存しました')));
                }
              },
              child: const Text('保存'),
            ),
          ],
        ),
      ),
    );
  }

    void _confirmDelete(Gutter gutter) {
    final currentLayer = _currentLayer;
    if (currentLayer == null) return;

    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('削除確認'),
        content: Text('${gutter.name} を削除しますか？'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('キャンセル')),
          TextButton(
            onPressed: () {
              setState(() {
                currentLayer.gutters.remove(gutter);
              });
              if (mounted) {
              ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('削除しました')));
              }
              Navigator.pop(context);
            },
            child: const Text('削除', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );
    _saveToLocalStorage();// 保存処理
  }

    void _showAllGutters() {
    final allPoints = layers
        .where((layer) => layer.visible)
        .expand((layer) => layer.gutters)
        .expand((g) => g.points)
        .toList();

    if (allPoints.isNotEmpty) {
      mapController.fitCamera(
        CameraFit.bounds(bounds: LatLngBounds.fromPoints(allPoints), padding: const EdgeInsets.all(60)),
      );
    }
  }

    Future<void> _getCurrentLocation() async {
    try {
      Position position = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.high,
          distanceFilter: 10,           // 10メートル移動するごとに更新（任意）
        ),
      );

      mapController.move(
        LatLng(position.latitude, position.longitude), 
        17.0,
      );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('位置情報取得失敗: $e')),
        );
      }
    }
  }

    void _renameLayer(int index) {
    final layer = layers[index];
    final controller = TextEditingController(text: layer.name);

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('レイヤー名変更'),
        content: TextField(controller: controller),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('キャンセル')),
          TextButton(
            onPressed: () {
              setState(() => layer.name = controller.text);
              Navigator.pop(ctx);
            },
            child: const Text('保存'),
          ),
        ],
      ),
    );
    _saveToLocalStorage();// 保存処理
  }

  void _createEmptyLayer() {
    setState(() {
      layers.add(GutterLayer(
        id: DateTime.now().millisecondsSinceEpoch.toString(),
        name: "新規レイヤー ${layers.length + 1}",
        gutters: [],
      ));
    });
    _saveToLocalStorage();// 保存処理
  }
  // ==================== カテゴリ色分けロジック ====================
  Color _getGutterColor(Gutter gutter, GutterLayer layer) {
    if (layer.categoryKey != null && layer.categoryColors.isNotEmpty) {
      final value = gutter.properties[layer.categoryKey!]?.toString() ?? '未分類';
      return layer.categoryColors[value] ?? Colors.grey;
    }
    return gutter.color;
  }

  // 現在選択中のレイヤーを返す
  GutterLayer? get _currentLayer {
    if (layers.isEmpty) return null;
    if (selectedLayerIndex != null && selectedLayerIndex! < layers.length) {
      return layers[selectedLayerIndex!];
    }
    return layers.first;
  }

  // ==================== カテゴリ色分け 補助メソッド ====================
  List<String> _getAllPropertyKeys(GutterLayer layer) {
    final keys = <String>{};
    for (var g in layer.gutters) {
      g.properties.keys.forEach(keys.add);
    }
    return keys.toList()..sort();
  }

  List<String> _getUniqueValues(GutterLayer layer, String? key) {
    if (key == null) return [];
    final values = <String>{};
    for (var g in layer.gutters) {
      final v = g.properties[key]?.toString() ?? '未分類';
      values.add(v);
    }
    return values.toList()..sort();
  }

  Map<String, Color> _generateCategoryColors(GutterLayer layer, String key) {
    final values = _getUniqueValues(layer, key);
    final colors = <String, Color>{};
    final palette = Colors.primaries + [Colors.brown, Colors.grey, Colors.pink, Colors.cyan];

    for (int i = 0; i < values.length; i++) {
      colors[values[i]] = palette[i % palette.length];
    }
    return colors;
  }
  // ==================== 流向矢印 ====================
  List<Polygon> _createFlowArrowPolygons() {
    final polygons = <Polygon>[];

    for (final layer in layers) {
      if (!layer.visible) continue;
      
      for (final gutter in layer.gutters) {
        if (!gutter.showArrow || gutter.points.length < 2) continue;

        final endPoint = gutter.points.last;
        final prevPoint = gutter.points[gutter.points.length - 2];

        final color = _getGutterColor(gutter, layer);
        
        final arrowPoints = _createArrowheadPolygonPoints(
          prevPoint, 
          endPoint, 
          sizeMeters: gutter.arrowSize,
        );

        polygons.add(Polygon(
          points: arrowPoints,
          color: color,
          borderColor: Colors.white,
          borderStrokeWidth: 1.5,
        ));
      }
    }
    return polygons;
  }

  /// 先端をライン終点に固定し、底辺を進行方向の後ろ側に正しく配置
  List<LatLng> _createArrowheadPolygonPoints(
    LatLng from, 
    LatLng to, 
    {double sizeMeters = 12.0}
  ) {
    // 方向ベクトル（メートル換算）
    final dy = to.latitude - from.latitude;
    final dx = to.longitude - from.longitude;
    
    final latRad = to.latitude * math.pi / 180;
    final meterPerDegLat = 111320.0;
    final meterPerDegLon = meterPerDegLat * math.cos(latRad);

    final vecY = dy * meterPerDegLat;
    final vecX = dx * meterPerDegLon;
    
    final length = math.sqrt(vecX * vecX + vecY * vecY);
    if (length < 0.000001) return [to, to, to];

    // 単位方向ベクトル
    final ux = vecX / length;  // 進行方向
    final uy = vecY / length;

    // 垂直単位ベクトル（右回り）
    final vx = -uy;
    final vy = ux;

    // 30度開度（半角15度）
    const double halfAngleDeg = 15.0;
    final halfAngleRad = halfAngleDeg * math.pi / 180;

    // 先端（頂点）はラインの終点に完全一致
    final tip = to;

    // 矢印の「高さ」（後ろにどれだけ伸びるか）
    final arrowLength = sizeMeters;

    // 底辺の半分の幅
    final halfWidth = arrowLength * math.tan(halfAngleRad);

    // 底辺の中心位置（先端から後ろに arrowLength だけ戻る）
    final baseCenterX = -ux * arrowLength;
    final baseCenterY = -uy * arrowLength;

    // 左翼（底辺左）
    final leftX = baseCenterX - vx * halfWidth;
    final leftY = baseCenterY - vy * halfWidth;

    // 右翼（底辺右）
    final rightX = baseCenterX + vx * halfWidth;
    final rightY = baseCenterY + vy * halfWidth;

    final left = LatLng(
      to.latitude  + leftY / meterPerDegLat,
      to.longitude + leftX / meterPerDegLon,
    );

    final right = LatLng(
      to.latitude  + rightY / meterPerDegLat,
      to.longitude + rightX / meterPerDegLon,
    );

    return [tip, left, right];
  }

    void _showCategoryStylingDialog(int layerIndex) {
    final layer = layers[layerIndex];
    final allKeys = _getAllPropertyKeys(layer);

    String? selectedKey = layer.categoryKey;
    Map<String, Color> tempColors = Map.from(layer.categoryColors);

    showDialog(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) {
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
                      const DropdownMenuItem(value: null, child: Text('無効（個別色を使う）')),
                      ...allKeys.map((key) => DropdownMenuItem(value: key, child: Text(key))),
                    ],
                    onChanged: (val) {
                      setDialogState(() {
                        selectedKey = val;
                        if (val != null) tempColors = _generateCategoryColors(layer, val);
                      });
                    },
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
                                final Color? pickedColor = await showDialog<Color>(
                                  context: context,   // ← ここを context に戻す
                                  builder: (dialogContext) => AlertDialog(  // ← c を dialogContext に変更
                                    title: Text('色を選択: $value'),
                                    content: Wrap(
                                      children: Colors.primaries.map((color) => GestureDetector(  // ← c を color に変更
                                        onTap: () => Navigator.pop(dialogContext, color),  // ← 修正
                                        child: Container(
                                          width: 48,
                                          height: 48,
                                          color: color,   // ← ここも修正
                                          margin: const EdgeInsets.all(4),
                                        ),
                                      )).toList(),
                                    ),
                                  ),
                                );
                                if (pickedColor != null) {
                                  setDialogState(() => tempColors[value] = pickedColor);
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
              TextButton(onPressed: () => Navigator.pop(context), child: const Text('キャンセル')),
              TextButton(
                onPressed: () {
                  setState(() {
                    layer.categoryKey = selectedKey;
                    layer.categoryColors = tempColors;
                  });
                  _saveToLocalStorage();
                  Navigator.pop(context);
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('色分け設定を適用しました')),
                  );
                },
                child: const Text('適用'),
              ),
            ],
          );
        },
      ),
    );
  }

@override
  Widget build(BuildContext context) {
    return Scaffold(
      key: _scaffoldKey,
      appBar: AppBar(
        title: Text(isAddingNew ? '新規追加モード' : isCutting ? '切断モード' : '側溝踏査マップ'),
        backgroundColor: isAddingNew ? Colors.orange : isCutting ? Colors.purple : Colors.blue,
        actions: [
          PopupMenuButton<String>(
            icon: const Icon(Icons.layers),
            onSelected: (value) => setState(() => currentTile = value),
            itemBuilder: (context) => [
              const PopupMenuItem(value: 'osm', child: Text('OpenStreetMap')),
              const PopupMenuItem(value: 'gsi_photo', child: Text('航空写真')),
            ],
          ),
          IconButton(
            icon: const Icon(Icons.menu),
            onPressed: () => _scaffoldKey.currentState?.openEndDrawer(),
          ),
        ],
      ),
      body: FlutterMap(
        mapController: mapController,
        options: MapOptions(
          initialCenter: const LatLng(36.555, 139.882),
          initialZoom: 17.0,
          onTap: _addPoint,
        ),
        children: [
          TileLayer(urlTemplate: getTileUrl(), userAgentPackageName: 'com.example.sideGutter_map'),
          ...layers.where((layer) => layer.visible).expand((layer) => [
                PolylineLayer(
                polylines: layer.gutters.map((g) => Polyline(
                  points: g.points,
                  color: _getGutterColor(g, layer),   // ← ここを変更
                  strokeWidth: g.strokeWidth,
                  borderStrokeWidth: 2.5,
                  borderColor: Colors.white,
                )).toList(),
              ),
              ]),

          // 新規追加中のライン（変更なし）
          if (isAddingNew && newPoints.isNotEmpty)
            PolylineLayer(
              polylines: [Polyline(points: newPoints, color: Colors.orange, strokeWidth: 7.5)],
            ),
          // 流向矢印（Polygon）
          ..._createFlowArrowPolygons().map((p) => PolygonLayer(
                polygons: [p],
                polygonCulling: false,
              )),
          ],
      ),
            endDrawer: Drawer(
        child: Column(
          children: [
            const DrawerHeader(
              decoration: BoxDecoration(color: Colors.blue),
              child: Center(
                child: Text(
                  'レイヤー管理',
                  style: TextStyle(color: Colors.white, fontSize: 20),
                ),
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
                      onChanged: (val) {
                        setState(() => layer.visible = val!);
                      },
                    ),
                    title: Text(layer.name),
                    subtitle: Text('${layer.gutters.length} 本'
                        '${layer.categoryKey != null ? " ・ ${layer.categoryKey}" : ""}'),
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
                          onPressed: () => _renameLayer(index),
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
      ),
      floatingActionButton: Column(
        mainAxisAlignment: MainAxisAlignment.end,
        children: [
          FloatingActionButton(heroTag: "all", mini: true, onPressed: _showAllGutters, child: const Icon(Icons.fullscreen)),
          const SizedBox(height: 8),
          if (isAddingNew)
            FloatingActionButton(heroTag: "save", onPressed: _saveNewGutter, child: const Icon(Icons.save)),
          const SizedBox(height: 8),
          FloatingActionButton(
            heroTag: "cut",
            backgroundColor: isCutting ? Colors.purple : null,
            onPressed: _toggleCutMode,
            child: const Icon(Icons.content_cut),
          ),
          const SizedBox(height: 8),
          FloatingActionButton(
            heroTag: "add",
            backgroundColor: isAddingNew ? Colors.red : Colors.green,
            onPressed: _toggleAddMode,
            child: Icon(isAddingNew ? Icons.close : Icons.add),
          ),
          const SizedBox(height: 8),
          FloatingActionButton(heroTag: "location", onPressed: _getCurrentLocation, child: const Icon(Icons.my_location)),
          const SizedBox(height: 8),
          FloatingActionButton(heroTag: "load", onPressed: _loadGeoJSON, child: const Icon(Icons.upload_file)),
          const SizedBox(height: 8),
          FloatingActionButton(heroTag: "export", onPressed: _exportGeoJSON, child: const Icon(Icons.download)),
          FloatingActionButton(
            heroTag: "url_load",
            onPressed: () {
              final controller = TextEditingController();
              showDialog(
                context: context,
                builder: (ctx) => AlertDialog(
                  title: const Text('GeoJSON URLから読み込み'),
                  content: TextField(
                    controller: controller,
                    decoration: const InputDecoration(hintText: 'https://gist.githubusercontent.com/...'),
                    maxLines: 3,
                  ),
                  actions: [
                    TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('キャンセル')),
                    TextButton(
                      onPressed: () {
                        Navigator.pop(ctx);
                        if (controller.text.trim().isNotEmpty) {
                          _loadGeoJSONFromUrl(controller.text.trim());
                        }
                      },
                      child: const Text('読み込み'),
                    ),
                  ],
                ),
              );
            },
            child: const Icon(Icons.link),
          ),
        ],
      ),
    );
  }
}