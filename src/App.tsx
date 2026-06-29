/**
 * @license
 * SPDX-License-Identifier: Apache-2.0
 */

import { Download, CheckCircle2 } from 'lucide-react';

export default function App() {
  return (
    <div className="min-h-screen bg-[#0A0A0B] flex flex-col items-center justify-center text-[#E4E4E7] p-6 font-sans">
      <div className="max-w-md w-full bg-[#161618] border border-[#27272A] rounded-xl p-8 shadow-[0_0_30px_rgba(6,182,212,0.1)] flex flex-col items-center text-center space-y-6">
        <div className="w-16 h-16 bg-[#06B6D4]/10 rounded-lg flex items-center justify-center shadow-[0_0_15px_rgba(6,182,212,0.2)] border border-[#06B6D4]/20">
          <CheckCircle2 className="w-8 h-8 text-[#06B6D4]" />
        </div>
        
        <div className="space-y-2">
          <h1 className="text-2xl font-bold tracking-tight text-white">VELO SPEEDER <span className="text-[#06B6D4] font-light">SWITCH</span></h1>
          <p className="text-zinc-400 text-sm font-medium tracking-wide">
            FLUTTER SOURCE CODE GENERATED
          </p>
          <p className="text-zinc-500 text-xs mt-2">
            I've applied the media remote patch and the Elegant Dark theme to your Dart code.
          </p>
        </div>

        <div className="w-full bg-[#0A0A0B] rounded-lg p-4 border border-[#27272A] text-left text-sm space-y-2">
          <p className="text-zinc-300 font-bold uppercase tracking-widest text-xs">Included files:</p>
          <ul className="text-zinc-500 space-y-1 list-none font-mono text-xs">
            <li className="flex items-center gap-2"><span className="text-[#06B6D4]">{'>'}</span> lib/main.dart</li>
            <li className="flex items-center gap-2"><span className="text-[#06B6D4]">{'>'}</span> pubspec.yaml</li>
            <li className="flex items-center gap-2"><span className="text-[#06B6D4]">{'>'}</span> android/app/src/main/AndroidManifest.xml</li>
            <li className="flex items-center gap-2"><span className="text-[#06B6D4]">{'>'}</span> ios/Runner/Info.plist</li>
          </ul>
        </div>

        <button className="w-full py-3 bg-zinc-800 hover:bg-zinc-700 text-white rounded-lg text-xs font-bold uppercase tracking-widest transition-colors flex items-center justify-center gap-2 group">
          <Download className="w-4 h-4 text-zinc-400 group-hover:text-white transition-colors" />
          Export as ZIP
        </button>
      </div>
    </div>
  );
}

