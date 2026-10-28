import Foundation

/// Maps real SDK light coordinates onto the selected motorcycle route without changing it.
/// This is conservative 2D matching, not a claim that every junction or road level is known.
enum RouteTrafficLights {
    struct Segment {
        let linkType: Int
        let formWay: Int
        let roadClass: Int
        var isSurface: Bool {
            // SDK: normal link=0; JCT/ramp/exit/entrance and their combinations are ambiguous.
            linkType == 0 && roadClass != 0 && formWay > 0 &&
                ![3,6,8,9,10,53,56,58].contains(formWay)
        }
    }
    struct Light { let point: MotorPoint; let along: Double }
    struct Result { let lights: [Light]; let rejected: Int }

    static func match(_ points: [MotorPoint], source: RouteShape, segments: [Segment], target: RouteShape) -> Result {
        var lights: [Light]=[], rejected=0
        for point in points {
            guard valid(point), let original=unambiguous(source,point:point), original.along>=25 else { rejected+=1;continue }
            let before=source.at(original.along-25)
            let approach=source.at(original.along-1)
            guard let entry=source.projections(approach,maximum:1).min(by:{abs($0.along-original.along)<abs($1.along-original.along)}),
                  entry.segment<source.roads.count else { rejected+=1;continue }
            let road=source.roads[entry.segment]
            guard !road.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty,
                  !ambiguousName(road),
                  safeSource(source,segments:segments,from:original.along-25,to:original.along+3,road:road),
                  let projected=target.match(point,back:before,road:road),
                  projected.along>=25,projected.offset<=4,
                  unambiguous(target,point:point) != nil,
                  RouteShape.metres(target.at(projected.along-25),before)<=5,
                  RouteShape.metres(target.at(projected.along-12.5),source.at(original.along-12.5))<=5,
                  RouteShape.angle(RouteShape.bearing(before,source.at(original.along)),
                                   RouteShape.bearing(target.at(projected.along-25),target.at(projected.along)))<=15,
                  safeTarget(target,from:projected.along-25,to:projected.along,road:road) else { rejected+=1;continue }
            if !lights.contains(where:{abs($0.along-projected.along)<8 && RouteShape.metres($0.point,point)<5}) {
                lights.append(Light(point:point,along:projected.along))
            }
        }
        return Result(lights:lights.sorted{$0.along<$1.along},rejected:rejected)
    }

    /// An intersecting or parallel passage elsewhere in the route cannot borrow this light.
    private static func unambiguous(_ shape: RouteShape, point: MotorPoint) -> RouteShape.Projection? {
        let candidates=shape.projections(point,maximum:12)
        guard let best=candidates.min(by:{$0.offset<$1.offset}),best.offset<=4,
              !candidates.contains(where:{abs($0.along-best.along)>35}) else { return nil }
        return best
    }
    private static func safeSource(_ shape: RouteShape, segments: [Segment], from: Double, to: Double, road: String) -> Bool {
        guard segments.count==shape.points.count-1 else { return false }
        let indices=window(shape,from:from,to:to)
        guard !indices.isEmpty,indices.allSatisfy({segments[$0].isSurface}) else { return false }
        // The entry road must agree for the whole 25 m approach; the outgoing road may differ.
        return window(shape,from:from,to:to-3).allSatisfy{$0<shape.roads.count && shape.roads[$0]==road}
    }
    private static func safeTarget(_ shape: RouteShape, from: Double, to: Double, road: String) -> Bool {
        let approach=window(shape,from:from,to:to)
        guard !approach.isEmpty,approach.allSatisfy({$0<shape.roads.count && shape.roads[$0]==road}) else { return false }
        // Web routes have no altitude. Reject explicit layer clues around the junction rather
        // than pretending the SDK ground-level coordinate proves the motorcycle route's level.
        return window(shape,from:from-15,to:to+15).allSatisfy {
            $0<shape.roads.count && !ambiguousName(shape.roads[$0])
        }
    }
    private static func window(_ shape: RouteShape, from: Double, to: Double) -> [Int] {
        guard shape.points.count>1 else { return [] }
        return (0..<(shape.points.count-1)).filter{shape.cum[$0+1]>from+0.01 && shape.cum[$0]<to-0.01}
    }
    private static func ambiguousName(_ name: String) -> Bool {
        ["高架","隧道","立交","匝道","快速路","高速","桥"].contains{ name.contains($0) }
    }
    private static func valid(_ p: MotorPoint) -> Bool {
        p.lat.isFinite && p.lng.isFinite && abs(p.lat)<=90 && abs(p.lng)<=180
    }

    /// Static junction distance only. A route count must never synthesize coordinates or lamp state.
    static func distance(_ lights: [Light], progress: Double, fresh: Bool) -> Int? {
        guard fresh,progress.isFinite,let next=lights.first(where:{$0.along>=progress}) else { return nil }
        let metres=next.along-progress
        return metres<=300 ? Int(metres.rounded()) : nil
    }
    static func packet(distance: Int?) -> String {
        guard let d=distance,d>=0,d<=300 else { return "#g" }
        return "#g,\(((d+5)/10)*10)"
    }
    static func positionsReady(matched: Int, rejected: Int, sourceCount: Int, routeCount: Int?) -> Bool {
        matched>0 || (rejected==0 && sourceCount==0 && routeCount==0)
    }
}
