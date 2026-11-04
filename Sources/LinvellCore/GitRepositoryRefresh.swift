import Foundation
import CryptoKit

extension GitRepository {
    /// Captures refs, index, pending operations and dirty working files without reading source contents.
    public func refreshFingerprint() throws -> String {
        if let remote {
            let program = #"""
import os,sys,json,hashlib,subprocess
root=sys.argv[1]
h=hashlib.sha256()
def git(args):
 p=subprocess.run(['git','--no-optional-locks','--no-pager','-C',root]+args,stdout=subprocess.PIPE,stderr=subprocess.PIPE)
 if p.returncode: raise RuntimeError(p.stderr.decode('utf-8','replace'))
 if len(p.stdout)>16*1024*1024: raise RuntimeError('Repository snapshot exceeds limits.')
 h.update(p.stdout)
 return p.stdout
status=git(['status','--porcelain=v1','-z','--untracked-files=all'])
git(['status','--porcelain=v2','--branch','-z','--untracked-files=all'])
git(['for-each-ref','--format=%(refname) %(objectname) %(upstream)'])
git(['worktree','list','--porcelain','-z'])
paths=[]; fields=status.split(b'\0'); i=0
while i<len(fields):
 record=fields[i]; i+=1
 if len(record)<4: continue
 paths.append(os.fsdecode(record[3:]))
 if record[:1] in (b'R',b'C') or record[1:2] in (b'R',b'C'):
  if i<len(fields): paths.append(os.fsdecode(fields[i])); i+=1
metadata=git(['rev-parse','--path-format=absolute','--git-dir','--git-common-dir']).decode().splitlines()
markers=['HEAD','index','config','packed-refs','MERGE_HEAD','MERGE_MSG','CHERRY_PICK_HEAD','REVERT_HEAD','BISECT_LOG','rebase-merge','rebase-apply']
paths=[os.path.join(root,p) for p in paths]+[os.path.join(folder,name) for folder in metadata for name in markers]
for path in paths:
 try:
  s=os.lstat(path); value=(path,s.st_mtime_ns,s.st_size,s.st_ino)
 except OSError: value=(path,None)
 h.update(repr(value).encode('utf-8','surrogateescape'))
print(h.hexdigest())
"""#
            let result = try ToolCommand.run(URL(fileURLWithPath:"/usr/bin/ssh"),arguments:remote.transportArguments(command:"python3 -c "+SSHRemote.quote(program)+" "+SSHRemote.quote(directory)),directory:nil,timeout:35)
            guard result.succeeded else { throw GitError.command(result.output) }
            return result.output.trimmingCharacters(in:.whitespacesAndNewlines)
        }
        var data = Data()
        func append(_ value: String) { data.append(Data(value.utf8)); data.append(0) }
        let status = try run(["status","--porcelain=v1","-z","--untracked-files=all"])
        append(try run(["status","--porcelain=v2","--branch","-z","--untracked-files=all"]))
        append(try run(["for-each-ref","--format=%(refname) %(objectname) %(upstream)"]))
        append(try run(["worktree","list","--porcelain","-z"]))
        let paths = Self.parseStatus(status).flatMap { [$0.path,$0.originalPath].compactMap { $0 } }
        var files = paths.map { root.appendingPathComponent($0) }
        for folder in try metadataDirectories() {
            files += ["HEAD","index","config","packed-refs","MERGE_HEAD","MERGE_MSG","CHERRY_PICK_HEAD","REVERT_HEAD","BISECT_LOG","rebase-merge","rebase-apply"].map { URL(fileURLWithPath:folder).appendingPathComponent($0) }
        }
        for file in files {
            append(file.path)
            if let attributes = try? FileManager.default.attributesOfItem(atPath:file.path) {
                append(String((attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0)); append(String(describing:attributes[.size])); append(String(describing:attributes[.systemFileNumber]))
            } else { append("missing") }
        }
        return SHA256.hash(data:data).map { String(format:"%02x",$0) }.joined()
    }
    public func metadataDirectories() throws -> [String] {
        try run(["rev-parse","--path-format=absolute","--git-dir","--git-common-dir"]).split(whereSeparator:\.isNewline).map(String.init)
    }
}
