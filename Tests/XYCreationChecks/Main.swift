import Foundation
import SoundModel
import SessionStore
import PlaybackRenderBridge

@main struct XYCreationChecks {
    @MainActor static func main() async {
        do {
            let log = try Log(URL(fileURLWithPath:CommandLine.arguments[1]))
            let h = try await Harness(log,"Public XY independent axes")
            let part = try await h.add("gain"), pad = fid(41,1)
            try await h.base(part,"gainDb",0.5)
            try await h.xy(pad,"Position",0.25,0.75,[0,0.2,1],[0,0.6,0.8,1])
            try log.require(h.edit.controls.first{$0.id==pad}?.face == .xy && h.edit.positions[LibraryControlAddress(path:[],control:pad)] == .xy(0.25,0.75),"real returned XY face/position/presentation")
            let choice = fid(41,2)
            try await h.choice(choice,"Door",[LibraryOption(id:fid(41,3),title:"Open",position:0),LibraryOption(id:fid(41,4),title:"Closed",position:1)],fid(41,3))
            let xlink=fid(41,5),ylink=fid(41,6)
            try await h.map("XY x selected setting",.connectOptions(id:xlink,source:LibraryMappingSource(pad,axis:.x),target:.setting(part:part,parameter:"gainDb"),selector:choice))
            try await h.map("XY y selected setting",.connect(id:ylink,source:LibraryMappingSource(pad,axis:.y),target:.setting(part:part,parameter:"gainDb")))
            for option in [fid(41,3),fid(41,4)] {
                try await h.lane(xlink,[(0,0),(0.2,0.2),(1,1)],option:option)
                try await h.lane(ylink,[(0,0),(0.6,0.6),(0.8,0.8),(1,1)],option:option)
            }
            // Axis-specific insertion admission checks that the nonidentical waypoint sets were retained.
            try await h.refuse("X rejects Y-only point",.point(binding:xlink,option:fid(41,3),position:0.6,value:0.6))
            try await h.refuse("Y rejects X-only point",.point(binding:ylink,option:fid(41,3),position:0.2,value:0.2))
            for (name,x,y,xs,ys) in [
                ("nanX",Double.nan,0.5,[0.0,1],[0.0,1]),
                ("infY",0.5,Double.infinity,[0,1],[0,1]),
                ("negativeX",-0.1,0.5,[0,1],[0,1]),
                ("highY",0.5,1.1,[0,1],[0,1]),
                ("emptyX",0.5,0.5,[],[0,1]),
                ("missingStartY",0.5,0.5,[0,1],[0.2,1]),
                ("missingEndX",0.5,0.5,[0,0.8],[0,1]),
                ("duplicateX",0.5,0.5,[0,0.2,0.2,1],[0,1]),
                ("reverseY",0.5,0.5,[0,1],[0,0.8,0.6,1]),
                ("nanWaypoint",0.5,0.5,[0,Double.nan,1],[0,1]),
                ("infWaypoint",0.5,0.5,[0,1],[0,Double.infinity,1]),
                ("outOfRangeWaypoint",0.5,0.5,[0,1.1,1],[0,1])] {
                try await h.refuse(name,.create(.xy(id:UUID(),title:name,initialX:x,initialY:y,xWaypoints:xs,yWaypoints:ys)))
            }
            try await h.refuse("duplicate control identity",.create(.xy(id:pad,title:"Duplicate",initialX:0,initialY:0,xWaypoints:[0,1],yWaypoints:[0,1])))
            for title in [""," \n\t"] {
                try await h.refuse("blank title",.create(.xy(id:UUID(),title:title,initialX:0,initialY:0,xWaypoints:[0,1],yWaypoints:[0,1])))
            }
            try await h.refuse("XY scalar axis mismatch",.connect(id:UUID(),source:LibraryMappingSource(pad),target:.setting(part:part,parameter:"gainDb")))
            try await h.refuse("choice x axis mismatch",.connect(id:UUID(),source:LibraryMappingSource(choice,axis:.x),target:.setting(part:part,parameter:"gainDb")))
            let ref = try await h.publish();try await h.attach(ref)
            try await h.moveXY(pad,0.1,0.9);try await h.moveXY(pad,0.8,0.2,iina)
            try await h.save();try await h.reopen()
            let state = try await h.session.snapshot()
            try log.require(state.uses.first{$0.target==safari}?.positions[pad] == .xy(0.1,0.9) && state.uses.first{$0.target==iina}?.positions[pad] == .xy(0.8,0.2),"XY independent exact saved app positions")
            let result:[String:Any] = ["passed":log.rows.filter{($0["ok"] as? Bool)==true}.count,"failed":log.rows.filter{($0["ok"] as? Bool)==false}.count]
            try JSONSerialization.data(withJSONObject:result,options:[.prettyPrinted,.sortedKeys]).write(to:log.directory.appendingPathComponent("RESULT.json"))
            print("XY RESULT \(result)");if log.rows.contains(where:{($0["ok"] as? Bool)==false}){exit(1)}
        } catch {print("XY CHECK FAILURE \(error)");exit(1)}
    }
}
