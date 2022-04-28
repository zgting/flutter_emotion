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

/// 定义函数 用于去调用c语言函数进行android的摄像头格式转换
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
  double totaltime = 0.0;
  double dealimgtime = 0.0;
  double yuvtorgbtime = 0.0;
  Color textcolor = Colors.black;
}

void main() {
    // 强制竖屏
    SystemChrome.setPreferredOrientations([
      DeviceOrientation.portraitUp,
      DeviceOrientation.portraitDown
    ]);
  runApp(MyApp());
}

class MyApp extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: '智能情感分析',
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
  String _posturl = "http://ip:5050"; //默认地址

  int isChinese = 0; //1是中文 0是英文
  //显示信息的中英文配置
  List _configtext = [
    [
      ["yuvtorgb_time:", "yuvtorgb时间:"],
      ["avg:", "平均:"],
      ["var:", "方差:"],
    ],
    [
      ["imgtobase_time:", "imgtobase时间:"],
      ["avg:", "平均:"],
      ["var:", "方差:"],
    ],
    [
      ["dealimg_time:", "dealimg时间:"],
      ["avg:", "平均:"],
      ["var:", "方差:"],
    ],
    [
      ["total_time:", "total时间:"],
      ["avg:", "平均:"],
      ["var:", "方差:"],
    ],
  ];
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
    //1是前摄像头 0是后摄像头
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

  //iso摄像头格式bgra转为rgb
  static imglib.Image _convertBGRA8888(CameraImage image) {
    return imglib.Image.fromBytes(
      image.width,
      image.height,
      image.planes[0].bytes,
      format: imglib.Format.bgra,
    );
  }

  //安卓前摄像头是YUV420转RGB
  static imglib.Image _yuvtoRgb(CameraImage cameraimage) {
    Stopwatch stopwatch = Stopwatch()..start();

    /// 加载我们定义的转换库
    final DynamicLibrary convertImageLib =
        DynamicLibrary.open("libconvertImage.so");

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
      person.dealimgtime = ma["seconds"]; //图片在服务器处理的时间
      // 给结果赋值
      person.isface = true;
      person.dominantemotion = ins['dominant_emotion'].toString();

      for (var item in person.emotion) {
        item.emotionValue = emotion[item.emotionText];
      }
    } on DioError catch (e) {
      print(e.toString());
    }
    // person.emotion
    //     .sort((left, right) => right.emotionValue > left.emotionValue ? 1 : -1);
    return person;
  }

  //测试参数的使用
  List<double> yuvtorgbl = []; //本地转img时间
  double yuvavg = 0.0;
  double yuvdx = 0.0;
  List<double> imagebase64l = []; //本地img转base64时间
  double imageavg = 0.0;
  double imagedx = 0.0;
  List<double> totaltimel = []; //总时间
  double totalavg = 0.0;
  double totaldx = 0.0;
  List<double> dealimgl = []; //服务器处理图片的时间
  double dealimgavg = 0.0;
  double dealimgdx = 0.0;

  double getavg(List li) {
    double avg = 0.0;
    for (var item in li) {
      avg += item;
    }
    avg /= li.length;
    return avg;
  }

  double getdx(List li, double avg) {
    double dx = 0.0;
    for (var item in li) {
      dx += (item - avg) * (item - avg);
    }
    dx /= li.length;
    return dx;
  }

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
        yuvtorgbl.add(_person.yuvtorgbtime);
        dealimgl.add(_person.dealimgtime);
        totaltimel.add(_person.totaltime);
        //imgtobase64
        imageavg = getavg(imagebase64l); //均值
        imagedx = getdx(imagebase64l, imageavg); //方差
        //yuv
        yuvavg = getavg(yuvtorgbl);
        yuvdx = getdx(yuvtorgbl, yuvavg);
        //dealimgavg
        dealimgavg = getavg(dealimgl);
        dealimgdx = getdx(dealimgl, dealimgavg);
        //total
        totalavg = getavg(totaltimel);
        totaldx = getdx(totaltimel, totalavg);
      }
      _isprocess = false;
    });
  }

  //将图片的List<Uint8>转为base64编码
  static String _imageToBase64(var image) {
    return "data:image/jpeg;base64," + base64Encode(image);
  }

  //对图片的主要处理
  static Future<void> solve(SendPort sendPort) async {
    ReceivePort port = ReceivePort();
    sendPort.send(port.sendPort);
    List msg = await port.first;

    CameraImage image = msg[0];

    SendPort replyto = msg[2];
    var yuvtorgb;
    yuvtorgb = DateTime.now();
    late imglib.Image img;
    //android进行yuv420转rgb iso进行bgra8888转rgb
    if (Platform.isAndroid)
      img = _yuvtoRgb(image);
    else if (Platform.isIOS || Platform.isMacOS) img = _convertBGRA8888(image);
    yuvtorgb = DateTime.now().difference(yuvtorgb);
    var imgtoBasetime;
    imgtoBasetime = DateTime.now();
    String base64Str = _imageToBase64(imglib.encodeJpg(img));
    imgtoBasetime = DateTime.now().difference(imgtoBasetime);
    var totaltime;
    totaltime = DateTime.now();
    Person person = await _postRequest(base64Str, msg[1]);
    totaltime = DateTime.now().difference(totaltime);
    person.yuvtorgbtime = yuvtorgb.inMicroseconds * 1.0 / 1000000; //转为秒
    person.imgtobase64 = imgtoBasetime.inMicroseconds * 1.0 / 1000000;
    person.totaltime = totaltime.inMicroseconds * 1.0 / 1000000;
    replyto.send(person);
  }

  //入口
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
          isChinese == 1 ? item.emotionChina : item.emotionText,
          style: TextStyle(color: _person.textcolor),
        ),
      ),
      Container(
        padding: EdgeInsets.only(right: 5, top: 4),
        width: MediaQuery.of(context).size.width * 4 / 5,
        child: LinearPercentIndicator(
          animation: true,
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

  //显示测试信息
  Widget buildTestInfo() {
    Widget content; //单独一个widget组件，用于返回需要生成的内容widget
    List<Widget> tiles = []; //先建一个数组用于存放循环生成的widget
    List testinfo = [
      [_person.yuvtorgbtime, yuvavg, yuvdx],
      [_person.imgtobase64, imageavg, imagedx],
      [_person.dealimgtime, dealimgavg, dealimgdx],
      [_person.totaltime, totalavg, totaldx]
    ]; //方便遍历
    for (int i = 0; i < _configtext.length; i++) {
      tiles.add(
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(_configtext[i][0][isChinese] +
                testinfo[i][0].toStringAsFixed(5) +
                " "),
            Text(_configtext[i][1][isChinese] +
                testinfo[i][1].toStringAsFixed(5) +
                " "),
            Text(_configtext[i][2][isChinese] +
                testinfo[i][2].toStringAsFixed(5)),
          ],
        ),
      );
    }
    content = Column(
      children: tiles,
    );
    return content;
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
              buildTestInfo(),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(isChinese == 1
                      ? "张数:"
                      : "pages:" + yuvtorgbl.length.toString()),
                ],
              ),
              // Row(
              //   mainAxisAlignment: MainAxisAlignment.center,
              //   children: [
              //     SizedBox(
              //       child: TextField(
              //         controller: _controller,
              //         decoration: InputDecoration(
              //           labelText: isChinese == 1
              //               ? "请输入IP和端口:"
              //               : "Pleae Input IP and port:",
              //           border: OutlineInputBorder(
              //               borderSide: BorderSide(color: Colors.red)),
              //         ),
              //       ),
              //       width: 220,
              //     ),
              //     SizedBox(
              //       width: 5,
              //     ),
              //     ElevatedButton(
              //       onPressed: () {
              //         _person.posturl = _controller.text;
              //       },
              //       child: Text(isChinese == 1 ? "更改IP:" : "change IP"),
              //     )
              //   ],
              // ),
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
