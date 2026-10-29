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
