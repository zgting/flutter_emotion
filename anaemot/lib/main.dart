import 'package:flutter/material.dart';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';
import 'package:dio/dio.dart';
import 'package:ffi/ffi.dart';
import 'package:camera/camera.dart';
import 'package:image/image.dart' as imglib;

/// 定义函数 用于去调用c语言函数进行转换
typedef ConvertFunc = Pointer<Uint32> Function(
    Pointer, Pointer, Pointer, Int32, Int32, Int32, Int32);
typedef Convert = Pointer<Uint32> Function(
    Pointer, Pointer, Pointer, int, int, int, int);

class Emotion {
  //需要显示的信息
  String dominantemotion = "NULL";
  double happy = 0.0;
  double angry = 0.0;
  double disgust = 0.0;
  double fear = 0.0;
  double neutral = 0.0;
  double sad = 0.0;
  double surprise = 0.0;
  bool isface = false;
}

void main() {
  runApp(MyApp());
}

class MyApp extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Analyse emotion',
      theme: ThemeData(
        primarySwatch: Colors.blue,
        visualDensity: VisualDensity.adaptivePlatformDensity,
      ),
      home: MyHomePage(title: 'Analyse emotion'),
    );
  }
}

class MyHomePage extends StatefulWidget {
  MyHomePage({Key? key, required this.title}) : super(key: key);
  final String title;
  @override
  _MyHomePageState createState() => _MyHomePageState();
}

class _MyHomePageState extends State {
  late CameraController _camera; //摄像头
  bool _cameraInitialized = false;
  Emotion _emotion = Emotion();
  //post推送的地址
  String posturl = "http://10.22.179.136:5050/analyze";
  var data;

  /// 加载我们定义的转换库
  final DynamicLibrary convertImageLib = Platform.isAndroid
      ? DynamicLibrary.open("libconvertImage.so")
      : DynamicLibrary.process();
  late Convert conv;

  @override
  void initState() {
    super.initState();
    _initializeCamera();

    // 安卓 在页面初始化时加载convertImage();
    conv = convertImageLib
        .lookup<NativeFunction<ConvertFunc>>('convertImage')
        .asFunction();
  }

  @override
  void dispose() {
    _camera.dispose();
    super.dispose();
  }

  void _initializeCamera() async {
    List cameras = await availableCameras();
    //0是前摄像头 1是后摄像头
    _camera = new CameraController(cameras[1], ResolutionPreset.high);
    _camera.initialize().then((_) async {
      // 开始采集数据流
      await _camera
          .startImageStream((CameraImage image) => _processCameraImage(image));
      setState(() {
        _cameraInitialized = true;
      });
    });
  }

  //将图片的List<Uint8>转为base64编码
  String _imageToBase64(var image) {
    return "data:image/jpeg;base64," + base64Encode(image);
  }

  //安卓前摄像头是YUV转RGB  ISO的话需要要BGR转RGB
  imglib.Image _yuvtoRgb(CameraImage cameraImage) {
    Stopwatch stopwatch = new Stopwatch()..start();
    // 由于转换函数返回的是指针，所以这里要提前分配内存
    Pointer<Uint8> p = malloc.allocate(cameraImage.planes[0].bytes.length);
    Pointer<Uint8> p1 = malloc.allocate(cameraImage.planes[1].bytes.length);
    Pointer<Uint8> p2 = malloc.allocate(cameraImage.planes[2].bytes.length);
    // 将图像数据分配给指针
    Uint8List pointerList = p.asTypedList(cameraImage.planes[0].bytes.length);
    Uint8List pointerList1 = p1.asTypedList(cameraImage.planes[1].bytes.length);
    Uint8List pointerList2 = p2.asTypedList(cameraImage.planes[2].bytes.length);
    pointerList.setRange(
        0, cameraImage.planes[0].bytes.length, cameraImage.planes[0].bytes);
    pointerList1.setRange(
        0, cameraImage.planes[1].bytes.length, cameraImage.planes[1].bytes);
    pointerList2.setRange(
        0, cameraImage.planes[2].bytes.length, cameraImage.planes[2].bytes);
    int w = 0;
    w = cameraImage.planes[1].bytesPerPixel!;
    // 调用convertImage函数将YUV转换为RGB
    Pointer<Uint32> imgP = conv(p, p1, p2, cameraImage.planes[1].bytesPerRow, w,
        cameraImage.width, cameraImage.height);
    // 获取返回的数据
    List<int> imgData =
        imgP.asTypedList((cameraImage.width * cameraImage.height));
    // 生成图像
    imglib.Image img =
        imglib.Image.fromBytes(cameraImage.height, cameraImage.width, imgData);
    //  水平翻转 安卓手机的前摄像头需要,后摄像头不需要这两句
    img.exif.orientation = 4;
    img = imglib.bakeOrientation(img);

    print("4 =====> ${stopwatch.elapsedMilliseconds}");
    // 释放内存
    malloc.free(p);
    malloc.free(p1);
    malloc.free(p2);
    malloc.free(imgP);
    return img;
  }

  ///post请求发送json
  void _postRequest(String base64str) async {
    List l1 = [];
    l1.add(base64str);

    ///创建Map 封装参数 {"img": ["base64_1","base64_2",...]}
    Map<String, dynamic> map = Map();
    map['img'] = l1;
    Response response;
    setState(() {
      _emotion.isface = false;
    });

    ///创建Dio
    Dio dio = new Dio();

    ///发起post请求
    response = await dio.post(posturl,
        data: map, options: Options(responseType: ResponseType.plain));
    setState(() {
      _emotion.isface = true;
    });
    data = response.data;
    var ma = jsonDecode(data.toString()); //字符串转map
    //print(data.toString());
    var ins = ma['instance_1'];
    var emotion = ins['emotion'];
    // 给结果赋值
    setState(() {
      _emotion.happy = emotion['happy'];
      _emotion.angry = emotion['angry'];
      _emotion.disgust = emotion['disgust'];
      _emotion.fear = emotion['fear'];
      _emotion.neutral = emotion['neutral'];
      _emotion.sad = emotion['sad'];
      _emotion.surprise = emotion['surprise'];
      _emotion.dominantemotion = ins['dominant_emotion'].toString();
    });
  }

  var lastPopTime = DateTime.now();
  //这里每隔2s分析一次
  void _processCameraImage(CameraImage image) async {
    if (DateTime.now().difference(lastPopTime) > Duration(seconds: 2)) {
      imglib.Image img = _yuvtoRgb(image);
      String base64Str = _imageToBase64(imglib.encodeJpg(img));
      _postRequest(base64Str);
      lastPopTime = DateTime.now();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text("Analyze emotion"),
      ),
      body: Center(
        child: Container(
          child: ListView(
            scrollDirection: Axis.vertical,
            children: [
              Container(
                  child: (_cameraInitialized)
                      ? AspectRatio(
                          aspectRatio: 3 / 4, //_camera.value.aspectRatio,
                          child: CameraPreview(_camera),
                        )
                      : CircularProgressIndicator()),
              //Text(data.toString()),
              SizedBox(
                height: 10,
              ),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [Text("isface  "), Text(_emotion.isface.toString())],
              ),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text("dominant_emotion  "),
                  Text(_emotion.dominantemotion)
                ],
              ),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [Text("happy  "), Text(_emotion.happy.toString())],
              ),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text("neutral  "),
                  Text(_emotion.neutral.toString())
                ],
              ),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [Text("angry  "), Text(_emotion.angry.toString())],
              ),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [Text("disgust "), Text(_emotion.disgust.toString())],
              ),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [Text("fear  "), Text(_emotion.fear.toString())],
              ),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text("surprise  "),
                  Text(_emotion.surprise.toString())
                ],
              ),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [Text("sad  "), Text(_emotion.sad.toString())],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
