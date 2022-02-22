import 'dart:isolate';
import 'package:flutter/material.dart';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';
import 'package:dio/dio.dart';
import 'package:ffi/ffi.dart';
import 'package:camera/camera.dart';
import 'package:image/image.dart' as imglib;
import 'package:percent_indicator/percent_indicator.dart';

/// 定义函数 用于去调用c语言函数进行转换
typedef ConvertFunc = Pointer<Uint32> Function(
    Pointer, Pointer, Pointer, Int32, Int32, Int32, Int32);
typedef Convert = Pointer<Uint32> Function(
    Pointer, Pointer, Pointer, int, int, int, int);

//每种情绪以及对应的占比Emotion
class Emotion {
  String emotionText = ""; //什么情绪
  String emotionChina = ""; //中文
  double emotionValue = 0.0; //该情绪的占比
}

//人脸类 各种情绪
class Person {
  String posturl = "";
  //需要显示的信息
  String dominantemotion = "NULL"; //主要的表情
  List<Emotion> emotion = [];
  bool isface = false;
  double imgtobase64 = 0.0;
  double postime = 0.0;
  double yuvtorgbtime = 0.0;
  Color textcolor = Colors.black;
}

void main() {
  runApp(MyApp());
}

class MyApp extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: '情绪分析',
      theme: ThemeData(
        primarySwatch: Colors.grey,
        visualDensity: VisualDensity.adaptivePlatformDensity,
      ),
      home: MyHomePage(),
    );
  }
}

class MyHomePage extends StatefulWidget {
  MyHomePage({Key? key}) : super(key: key);
  @override
  _MyHomePageState createState() => _MyHomePageState();
}

class _MyHomePageState extends State {
  late CameraController _camera; //摄像头
  Person _person = Person();
  bool _cameraInitialized = false;
  bool _isprocess = false;
  //post推送的地址
  TextEditingController _controller = TextEditingController();
  String _posturl = "http://10.22.179.136:5050";
  //static String _posturl = "http://192.168.0.104:5050/analyze";
  //static String _posturl = "http://155.138.220.251:5000/analyze";

  @override
  void initState() {
    super.initState();
    _controller.text = _posturl;
    _person.posturl = _posturl;
    //初始话表情类
    _initialEmotion();
    //初始化摄像头
    _initializeCamera();
  }

  @override
  void dispose() {
    _camera.dispose();
    super.dispose();
  }

  //初始化表情参数
  void _initialEmotion() {
    List em = [
      ["neutral", "中立"],
      ["happy", "高兴"],
      ["disgust", "厌恶"],
      ["fear", "害怕"],
      ["sad", "伤心"],
      ["surprise", "惊喜"],
      ["angry", "生气"]
    ];
    for (var item in em) {
      Emotion emotion = Emotion();
      emotion.emotionText = item[0];
      emotion.emotionChina = item[1];
      _person.emotion.add(emotion);
    }
  }

  // 初始化摄像头参数
  void _initializeCamera() async {
    List cameras = await availableCameras();
    //0是前摄像头 1是后摄像头
    _camera = new CameraController(cameras[1], ResolutionPreset.low);
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
  static String _imageToBase64(var image) {
    return "data:image/jpeg;base64," + base64Encode(image);
  }

  //安卓前摄像头是YUV转RGB  ISO的话需要要BGR转RGB
  static imglib.Image _yuvtoRgb(CameraImage cameraimage) {
    Stopwatch stopwatch = Stopwatch()..start();

    /// 加载我们定义的转换库
    final DynamicLibrary convertImageLib = Platform.isAndroid
        ? DynamicLibrary.open("libconvertImage.so")
        : DynamicLibrary.process();

    // 安卓 在页面初始化时加载convertImage();
    Convert conv = convertImageLib
        .lookup<NativeFunction<ConvertFunc>>('convertImage')
        .asFunction();

    // 由于转换函数返回的是指针，所以这里要提前分配内存
    Pointer<Uint8> p = malloc.allocate(cameraimage.planes[0].bytes.length);
    Pointer<Uint8> p1 = malloc.allocate(cameraimage.planes[1].bytes.length);
    Pointer<Uint8> p2 = malloc.allocate(cameraimage.planes[2].bytes.length);

    // 将图像数据分配给指针
    Uint8List pointerList = p.asTypedList(cameraimage.planes[0].bytes.length);
    Uint8List pointerList1 = p1.asTypedList(cameraimage.planes[1].bytes.length);
    Uint8List pointerList2 = p2.asTypedList(cameraimage.planes[2].bytes.length);
    pointerList.setRange(
        0, cameraimage.planes[0].bytes.length, cameraimage.planes[0].bytes);
    pointerList1.setRange(
        0, cameraimage.planes[1].bytes.length, cameraimage.planes[1].bytes);
    pointerList2.setRange(
        0, cameraimage.planes[2].bytes.length, cameraimage.planes[2].bytes);
    int w = 0;
    w = cameraimage.planes[1].bytesPerPixel!;

    // 调用convertImage函数将YUV转换为RGB
    Pointer<Uint32> imgP = conv(p, p1, p2, cameraimage.planes[1].bytesPerRow, w,
        cameraimage.width, cameraimage.height);
    // 获取返回的数据
    List<int> imgData =
        imgP.asTypedList((cameraimage.width * cameraimage.height));
    // 生成图像
    imglib.Image img =
        imglib.Image.fromBytes(cameraimage.height, cameraimage.width, imgData);
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
  static Future<Person> _postRequest(String base64str, Person person) async {
    ///创建Map 封装参数 {"img": ["base64_1","base64_2",...]}
    Map<String, dynamic> map = Map();
    List l1 = [];
    l1.add(base64str);
    map['img'] = l1;

    ///创建Dio
    Dio dio = new Dio();

    ///发起post请求
    Response response;
    try {
      response = await dio.post(person.posturl + "/analyze",
          data: map, options: Options(responseType: ResponseType.plain));
      //能到这里就说明检测到脸了
      var data = response.data;
      var ma = jsonDecode(data.toString()); //字符串转map

      var ins = ma['instance_1'];
      var emotion = ins['emotion'];

      // 给结果赋值
      person.isface = true;
      person.dominantemotion = ins['dominant_emotion'].toString();

      for (var item in person.emotion) {
        item.emotionValue = emotion[item.emotionText];
      }
    } on DioError catch (e) {}
    // person.emotion
    //     .sort((left, right) => right.emotionValue > left.emotionValue ? 1 : -1);
    return person;
  }

  List<double> yuvtorgbl = [];
  double yuvavg = 0.0;
  double yuvdx = 0.0;
  List<double> imagebase64l = [];
  double imageavg = 0.0;
  double imagedx = 0.0;
  List<double> posttimel = [];
  double postavg = 0.0;
  double postdx = 0.0;
  //处理图片
  _dealimage(CameraImage image) async {
    setState(() {
      _person.isface = false;
    });
    // 启动一个线程去处理图片
    ReceivePort receivePort = ReceivePort();
    await Isolate.spawn(solve, receivePort.sendPort);
    SendPort sendPort = await receivePort.first;
    ReceivePort response = ReceivePort();
    sendPort.send([image, _person, response.sendPort]);
    Person msg = await response.first;
    setState(() {
      if (msg.isface) {
        _person = msg;
        imagebase64l.add(_person.imgtobase64);
        posttimel.add(_person.postime);
        yuvtorgbl.add(_person.yuvtorgbtime);
        imageavg = 0.0; //均值
        for (var item in imagebase64l) {
          imageavg += item;
        }
        imageavg /= imagebase64l.length;
        imagedx = 0.0; //方差
        for (var item in imagebase64l) {
          imagedx += (item - imageavg) * (item - imageavg);
        }
        imagedx /= imagebase64l.length;
        postavg = 0.0;
        for (var item in posttimel) {
          postavg += item;
        }
        postavg /= posttimel.length;
        postdx = 0.0;
        for (var item in posttimel) {
          postdx += (item - postavg) * (item - postavg);
        }
        postdx /= posttimel.length;
        yuvavg = 0.0;
        for (var item in yuvtorgbl) {
          yuvavg += item;
        }
        yuvavg /= yuvtorgbl.length;
        yuvdx = 0.0;
        for (var item in yuvtorgbl) {
          yuvdx += (item - yuvavg) * (item - yuvavg);
        }
        yuvdx /= yuvtorgbl.length;
      }
      _isprocess = false;
    });
  }

  static Future<void> solve(SendPort sendPort) async {
    ReceivePort port = ReceivePort();
    sendPort.send(port.sendPort);
    List msg = await port.first;

    CameraImage image = msg[0];

    SendPort replyto = msg[2];
    var yuvtorgb;
    yuvtorgb = DateTime.now();
    imglib.Image img = _yuvtoRgb(image);
    yuvtorgb = DateTime.now().difference(yuvtorgb);
    var imgtoBasetime;
    imgtoBasetime = DateTime.now();
    String base64Str = _imageToBase64(imglib.encodeJpg(img));
    imgtoBasetime = DateTime.now().difference(imgtoBasetime);
    var posttime;
    posttime = DateTime.now();
    Person person = await _postRequest(base64Str, msg[1]);
    posttime = DateTime.now().difference(posttime);
    person.yuvtorgbtime = yuvtorgb.inMicroseconds * 1.0 / 1000000;
    person.imgtobase64 = imgtoBasetime.inMicroseconds * 1.0 / 1000000;
    person.postime = posttime.inMicroseconds * 1.0 / 1000000;
    replyto.send(person);
  }

  void _processCameraImage(CameraImage image) async {
    if (!_isprocess) {
      _isprocess = true;
      _dealimage(image);
    }
  }

  //显示表情
  Widget buildEmotion() {
    Widget content; //单独一个widget组件，用于返回需要生成的内容widget
    List<Widget> tiles = []; //先建一个数组用于存放循环生成的widget

    for (var item in _person.emotion) {
      tiles.add(
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: emotionInfo(item),
        ),
      );
    }
    content = Column(
      children: tiles,
    );
    return content;
  }

  //显示的表情信息
  List<Widget> emotionInfo(Emotion item) {
    return [
      Container(
        padding: EdgeInsets.only(left: 10, bottom: 5),
        width: MediaQuery.of(context).size.width / 5,
        child: Text(
          item.emotionChina,
          style: TextStyle(color: _person.textcolor),
        ),
      ),
      Container(
        padding: EdgeInsets.only(right: 5, top: 4),
        width: MediaQuery.of(context).size.width * 4 / 5,
        child: LinearPercentIndicator(
          animation: true,
          // leading: Image(
          //   image: AssetImage(
          //     "assets/images/mine/" + item.emotionText + ".png",
          //   ),
          //   width: 18,
          //   height: 18,
          // ),
          lineHeight: 20.0,
          animationDuration: 250,
          percent: item.emotionValue / 100,
          center: Text(item.emotionValue.toStringAsFixed(4) + "%"),
          linearStrokeCap: LinearStrokeCap.roundAll,
          animateFromLastPercent: true,
          linearGradient: LinearGradient(
            begin: Alignment.centerLeft,
            end: Alignment(2.0, 2.0),
            colors: [Colors.green, Colors.red],
          ),
        ),
      ),
    ];
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Container(
        color: Colors.blueGrey,
        child: Center(
          child: ListView(
            scrollDirection: Axis.vertical,
            children: [
              Container(
                child: _cameraInitialized
                    ? AspectRatio(
                        aspectRatio: 3 / 4, //_camera.value.aspectRatio,
                        child: CameraPreview(_camera),
                      )
                    : CircularProgressIndicator(),
              ),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text("yuvtorgb时间" +
                      _person.yuvtorgbtime.toStringAsFixed(5) +
                      " "),
                  Text("平均" + yuvavg.toStringAsFixed(5) + " "),
                  Text("方差" + yuvdx.toStringAsFixed(5)),
                ],
              ),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text("imgtobase时间" +
                      _person.imgtobase64.toStringAsFixed(5) +
                      " "),
                  Text("平均" + imageavg.toStringAsFixed(5) + " "),
                  Text("方差" + imagedx.toStringAsFixed(5)),
                ],
              ),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text("post时间" + _person.postime.toStringAsFixed(5) + " "),
                  Text("平均" + postavg.toStringAsFixed(5) + " "),
                  Text("方法" + postdx.toStringAsFixed(5)),
                ],
              ),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text("张数:" + yuvtorgbl.length.toString()),
                ],
              ),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  SizedBox(
                    child: TextField(
                      controller: _controller,
                      decoration: InputDecoration(
                        labelText: "请输入IP和端口：",
                        border: OutlineInputBorder(
                            borderSide: BorderSide(color: Colors.red)),
                      ),
                    ),
                    width: 260,
                  ),
                  ElevatedButton(
                    onPressed: () {
                      _person.posturl = _controller.text;
                    },
                    child: Text("更换IP"),
                  )
                ],
              ),
              SizedBox(
                height: 10,
              ),
              buildEmotion(),
            ],
          ),
        ),
      ),
    );
  }
}
