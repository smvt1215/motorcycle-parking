import '../models/parking.dart';

/// 選擇車種 (P2) 的說明文字.
const vehicleSheetIntro = '地圖上的「能不能停」會依車種更新。';

/// The plates a class is known by.
String vehiclePlates(VehicleType vehicle) => switch (vehicle) {
  VehicleType.scooter => '綠牌・白牌，未滿 250cc',
  VehicleType.heavy => '紅牌・黃牌，250cc 以上',
};

/// What choosing the class changes on the map.
String vehicleEffect(VehicleType vehicle) => switch (vehicle) {
  VehicleType.scooter => '可停一般機車格與普大共用格；重機專用格不能停',
  VehicleType.heavy => '可停重機專用格、普大共用格；一般機車格與汽車格依縣市規則',
};
