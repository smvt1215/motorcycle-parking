// Conservative query bounds derived from g0v/twgeojson (CC0 1.0), accessed 2026-10-11.
// https://github.com/g0v/twgeojson/blob/master/json/twCounty2010.geo.json
// Coordinates padded by .03 degrees; used only to choose TDX city endpoints,
// never to determine parking law or assign a point to a city.
export const cityBounds: Record<
  string,
  readonly [number, number, number, number]
> = {
  TaitungCounty: [21.914374, 120.709079, 23.473763, 121.644893],
  YilanCounty: [24.279448, 121.286739, 25.018445, 121.996004],
  Taipei: [24.930494, 121.427073, 25.240181, 121.695928],
  YunlinCounty: [23.405688, 119.966909, 23.876879, 120.766154],
  Taoyuan: [24.556417, 120.956036, 25.153171, 121.509846],
  PingtungCounty: [21.866607, 120.322867, 22.915156, 120.934195],
  Taichung: [23.968486, 120.430781, 24.471709, 121.480999],
  Tainan: [22.857483, 120.001591, 23.443727, 120.686253],
  Keelung: [25.022468, 121.596787, 25.225604, 121.838185],
  LienchiangCounty: [25.909604, 119.884213, 26.418021, 120.547079],
  NantouCounty: [23.405195, 120.585548, 24.276281, 121.379432],
  PenghuCounty: [23.156559, 119.284282, 23.828323, 119.757541],
  MiaoliCounty: [24.258495, 120.591175, 24.771105, 121.292622],
  Chiayi: [23.409564, 120.359181, 23.548334, 120.539361],
  HsinchuCounty: [24.397499, 120.902069, 24.976371, 121.44233],
  NewTaipei: [24.643173, 121.252669, 25.331128, 122.037089],
  HualienCounty: [23.067783, 120.956596, 24.400528, 121.803553],
  Kaohsiung: [22.445591, 120.14502, 23.501693, 121.079029],
  ChanghuaCounty: [23.75559, 120.212238, 24.227417, 120.713944],
  ChiayiCounty: [23.184779, 120.087346, 23.665916, 120.987585],
  KinmenCounty: [24.355452, 118.181348, 24.560203, 118.508399],
  Hsinchu: [24.682604, 120.848515, 24.884067, 121.063552],
};
