import Foundation
// Explicit synthetic protocol inputs; not real lamp data or road validation.
let body=Data(#"{"data":[{}],"extend":"{\"pathID\":\"27\"}"}"#.utf8)
func words(_ path:UInt32=27,_ status:Int32=2,_ count:Int32=18)->Data {
    var result=Data()
    for w in [path,UInt32(bitPattern:status),UInt32(bitPattern:count),0,0,0,0,0,0,0] {
        for n in 0..<4 { result.append(UInt8((w >> (8*n))&255)) }
    };return result
}
func decode(_ signals:Data=words(),_ payload:Data=body,_ owner:UInt64=9,_ active:UInt64=9,_ at:Double=100,_ now:Double=100.2)->[NativeCountdownEvidence]? {
    NativeCountdownEvidence.decode(body:payload,signals:signals,owner:owner,currentOwner:active,capturedAt:at,now:now)
}
precondition(decode()==[.init(rawStatus:2,seconds:18)])
precondition(decode(words(28))==nil)
precondition(decode(words(),body,8,9)==nil)
precondition(decode(words(),body,0,0)==nil)
precondition(decode(words(),body,9,9,100,103)==nil)
precondition(decode(words(),body,9,9,100,99)==nil)
precondition(decode(words(),body,9,9,.nan,100)==nil)
precondition(decode(words(),body,9,9,100,.infinity)==nil)
precondition(decode(words(27,2,0))==nil)
precondition(decode(words(27,2,1000))==nil)
precondition(decode(words(27,40000,18))==nil)
precondition(decode(Data())==nil)
precondition(decode(Data(words().dropLast()))==nil)
precondition(decode(Data(repeating:0,count:33*40))==nil)
precondition(decode(words(),Data("not JSON".utf8))==nil)
precondition(decode(words(),Data(#"{"data":[],"extend":"{}"}"#.utf8))==nil)
print("Native countdown evidence: 16 boundary checks passed (synthetic inputs)")

func diagnostic(status:Int?=nil,seconds:Int?=nil,at:Double?=nil,uptime:Double=100,
                mode:String="simulation",active:Bool=true,extraCounter:Bool=false,
                verified:Bool=false)->NativeCountdownDiagnostics {
    var counters=Dictionary(uniqueKeysWithValues:NativeCountdownDiagnostics.counterNames.map { ($0,UInt64(0)) })
    counters["enabled"]=active ? 1 : 0; counters["epoch"]=9
    if extraCounter { counters["arbitraryResponseField"]=1 }
    return .init(schema:1,version:"0.15.18",build:18,runID:"4FAC1EF8-7F63-4F16-A58D-11673E4FF974",
        active:active,mode:mode,owner:9,uptime:uptime,counters:counters,decoderAccepted:0,decoderRejected:0,
        lastRawStatus:status,lastRawSeconds:seconds,sampleUptime:at,
        colourAndDirectionVerified:verified,roundDisplayCountdownEnabled:false)
}
let valid=diagnostic()
let encoded=valid.encoded()!
let decoded=try JSONDecoder().decode(NativeCountdownDiagnostics.self,from:encoded)
precondition(decoded==valid)
precondition(encoded.count<8192)
precondition(diagnostic(status:2,seconds:18,at:99).encoded() != nil)
precondition(diagnostic(status:2,seconds:0,at:99).encoded()==nil)
precondition(diagnostic(status:40000,seconds:18,at:99).encoded()==nil)
precondition(diagnostic(status:2,seconds:18,at:101).encoded()==nil)
precondition(diagnostic(status:2).encoded()==nil)
precondition(diagnostic(uptime:.infinity).encoded()==nil)
precondition(diagnostic(mode:"gps").encoded() != nil)
precondition(diagnostic(mode:"idle",active:false).encoded() != nil)
precondition(diagnostic(mode:"idle",active:true).encoded()==nil)
precondition(diagnostic(extraCounter:true).encoded()==nil)
precondition(diagnostic(verified:true).encoded()==nil)
print("Native diagnostic snapshot: 13 format, bounds, mode and isolation checks passed (synthetic inputs)")
