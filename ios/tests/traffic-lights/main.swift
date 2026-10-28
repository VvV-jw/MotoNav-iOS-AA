import Foundation

// This harness compiles the production geometry using the same minimal coordinate value type.
struct MotorPoint { let lat: Double; let lng: Double; var name=""; var id="" }
func point(_ x: Double,_ y: Double) -> MotorPoint {
    MotorPoint(lat:30+y/111320,lng:104+x/(111320*cos(30 * .pi/180)))
}
func shape(_ xy: [(Double,Double)],_ roads: [String]?=nil) -> RouteShape {
    RouteShape(points:xy.map{point($0.0,$0.1)},roads:roads ?? [String](repeating:"测试路",count:max(0,xy.count-1)))
}
func segments(_ source: RouteShape,linkType: Int=0,formWay: Int=15) -> [RouteTrafficLights.Segment] {
    [RouteTrafficLights.Segment](repeating:.init(linkType:linkType,formWay:formWay,roadClass:9),count:max(0,source.points.count-1))
}
let source=shape([(0,0),(0,100),(0,200),(0,400)])
let bulb=point(0,200)
func matched(_ target: RouteShape,_ src: RouteShape=source,_ metadata: [RouteTrafficLights.Segment]?=nil,_ lights: [MotorPoint]=[bulb]) -> RouteTrafficLights.Result {
    RouteTrafficLights.match(lights,source:src,segments:metadata ?? segments(src),target:target)
}
let accepted=matched(source)
precondition(accepted.lights.count==1 && abs(accepted.lights[0].along-200)<0.1)
precondition(abs(accepted.lights[0].point.lng-bulb.lng)<0.00000001) // original SDK coordinate retained
precondition(matched(source,source,nil,[bulb,bulb]).lights.count==1)
precondition(matched(shape([(0,0),(0,400)],["另一条路"])).lights.isEmpty)
precondition(matched(shape([(0,400),(0,0)])).lights.isEmpty)
precondition(matched(shape([(8,0),(8,400)])).lights.isEmpty)
precondition(matched(shape([(-200,200),(200,200)])).lights.isEmpty)
// A return passage at this same intersection makes road/approach attribution ambiguous.
let loop=shape([(0,0),(0,400),(100,400),(100,0),(0,0),(0,400)])
precondition(matched(loop).lights.isEmpty)
precondition(matched(source,loop).lights.isEmpty)
// A source SDK light on a bridge/tunnel/elevated/unknown link cannot become a surface junction.
for link in [-1,2,3,4] { precondition(matched(source,source,segments(source,linkType:link)).lights.isEmpty) }
for form in [-1,3,6,8,9,10] { precondition(matched(source,source,segments(source,formWay:form)).lights.isEmpty) }
precondition(matched(shape([(0,0),(0,400)],["测试高架路"])).lights.isEmpty)
precondition(matched(shape([(0,0),(0,180),(0,200),(0,400)],["测试路","","测试路"])).lights.isEmpty)
precondition(matched(source,source,[]).lights.isEmpty) // absent layer metadata is not a normal link
precondition(matched(source,source,nil,[MotorPoint(lat:.nan,lng:104)]).lights.isEmpty)
// A different 25m entry segment must not borrow the light at a common endpoint.
precondition(matched(shape([(-100,150),(-20,175),(0,200),(0,400)])).lights.isEmpty)
print("PASS static lights: original coordinates, road/approach, parallel, crossing, loop and layer rejection")

precondition(RouteTrafficLights.distance(accepted.lights,progress:0,fresh:true)==200)
precondition(RouteTrafficLights.distance(accepted.lights,progress:190,fresh:true)==10)
precondition(RouteTrafficLights.distance(accepted.lights,progress:201,fresh:true)==nil)
precondition(RouteTrafficLights.distance(accepted.lights,progress:0,fresh:false)==nil)
precondition(RouteTrafficLights.distance(accepted.lights,progress:.nan,fresh:true)==nil)
precondition(RouteTrafficLights.packet(distance:300)=="#g,300")
precondition(RouteTrafficLights.packet(distance:301)=="#g")
precondition(RouteTrafficLights.packet(distance:nil)=="#g")
precondition(!RouteTrafficLights.positionsReady(matched:0,rejected:0,sourceCount:12,routeCount:12))
precondition(!RouteTrafficLights.positionsReady(matched:0,rejected:0,sourceCount:0,routeCount:nil))
precondition(!RouteTrafficLights.positionsReady(matched:0,rejected:1,sourceCount:0,routeCount:0))
precondition(RouteTrafficLights.positionsReady(matched:0,rejected:0,sourceCount:0,routeCount:0))
precondition(RouteTrafficLights.positionsReady(matched:1,rejected:2,sourceCount:3,routeCount:8))
print("PASS static lights: 300m boundary, stale/invalid fixes, passed junction and unknown-versus-zero state")
