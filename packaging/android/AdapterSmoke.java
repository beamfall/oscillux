// SPDX-License-Identifier: AGPL-3.0-only
import org.oscillux.Oscillux;
import java.nio.ByteBuffer;
import java.nio.ByteOrder;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.List;

/** Run against the actual JNI adapter; expected DSP values are the pinned fixture. */
public final class AdapterSmoke {
    static void require(boolean value) { if (!value) throw new AssertionError(); }
    /** Config buffer from tokens columns rows fieldWidth fieldHeight maxFieldArea maxFlashHz maxRedFlashes redRule. */
    static ByteBuffer flashConfig(String[] v, int at) {
        ByteBuffer config=Oscillux.buffer(Oscillux.flashConfigSize());
        config.putInt(0,Oscillux.flashConfigSize());
        require(Oscillux.flashConfigDefault(config)==0);
        config.putInt(4,(int)Double.parseDouble(v[at])); config.putInt(8,(int)Double.parseDouble(v[at+1])); config.putInt(12,(int)Double.parseDouble(v[at+6]));
        for (int k=0;k<4;k++) config.putDouble(16+k*8,Double.parseDouble(v[at+2+k]));
        config.putInt(48,(int)Double.parseDouble(v[at+7]));
        return config;
    }
    /**
     * Runs conformance/limiter/region-sequences.json, flattened by tools/jni-smoke.py, through the
     * FlashAnalyzer binding; returns the number of sequence cases.
     */
    static int regionFlash(Path fixture) throws Exception {
        require(Oscillux.flashConfigSize()==56 && Oscillux.flashRegionSize()==16 && Oscillux.flashColorSize()==24 && Oscillux.flashReportSize()==48);
        ByteBuffer defaults=Oscillux.buffer(56);
        require(Oscillux.flashConfigDefault(defaults)<0);
        defaults.putInt(0,56);
        require(Oscillux.flashConfigDefault(defaults.asReadOnlyBuffer())<0 && Oscillux.flashConfigDefault(defaults)==0);
        require(defaults.getInt(4)==16 && defaults.getInt(8)==16 && defaults.getDouble(40)==3 && defaults.getInt(48)==0 && defaults.getInt(52)==0);
        // The first released size, 48, writes only its own bytes and selects the WCAG 2.0 red rule.
        defaults.putInt(0,48); defaults.putInt(48,7);
        require(Oscillux.flashConfigDefault(defaults)==0 && defaults.getInt(48)==7);
        new Oscillux.FlashAnalyzer(defaults).close();
        ByteBuffer regions=Oscillux.buffer(256*16), colors=Oscillux.buffer(256*24), report=Oscillux.buffer(48);
        double tolerance=0;
        int cases=0, firstExceeds=-1, refusals=0, isoCases=0;
        Oscillux.FlashAnalyzer analyzer=null;
        String name="", mode="";
        for (String line: Files.readAllLines(fixture)) {
            String[] v=line.split(" ");
            switch (v[0]) {
                case "tolerance": tolerance=Double.parseDouble(v[1]); break;
                case "validation": {
                    ByteBuffer config=flashConfig(v,3);
                    if (v[2].equals("ok")) new Oscillux.FlashAnalyzer(config).close();
                    else { try { new Oscillux.FlashAnalyzer(config).close(); require(false); } catch (IllegalArgumentException refused) { } }
                    break;
                }
                case "case": {
                    if (analyzer!=null) analyzer.close();
                    name=v[1]; mode=v[2]; cases++;
                    analyzer=new Oscillux.FlashAnalyzer(flashConfig(v,3));
                    if (Double.parseDouble(v[10])==1) {
                        // The ISO 9241-391 rule refuses the sample path and leaves the analyzer unchanged.
                        regions.putDouble(0,0); regions.putDouble(8,0);
                        require(analyzer.measure(0,regions,1,report)<0 && report.getInt(24)==0);
                        isoCases++;
                    }
                    break;
                }
                case "frame": {
                    int n=(v.length-3-8)/2;
                    double t=Double.parseDouble(v[1]);
                    if (v[2].equals("1")) require(analyzer.reset()==0);
                    for (int r=0;r<n;r++) { regions.putDouble(r*16,Double.parseDouble(v[3+r])); regions.putDouble(r*16+8,Double.parseDouble(v[3+n+r])); }
                    require((mode.equals("admit") ? analyzer.admit(t,regions,n,report) : analyzer.measure(t,regions,n,report))==0);
                    int e=3+2*n;
                    require(report.getDouble(0)==t);
                    for (int k=0;k<3;k++) require(report.getInt(24+k*4)==(int)Double.parseDouble(v[e+k]));
                    require(report.getInt(36)==(int)Double.parseDouble(v[e+3]) && report.getInt(40)==(int)Double.parseDouble(v[e+4]));
                    require(report.getDouble(8)==Double.parseDouble(v[e+5]) && report.getDouble(16)==Double.parseDouble(v[e+6]));
                    require(report.getInt(44)==(int)Double.parseDouble(v[e+7]));
                    if (name.equals("full-screen-0.15-10hz-measure") && report.getInt(44)==1 && firstExceeds<0) firstExceeds=(int)t;
                    if (name.equals("full-screen-0.15-10hz-admit") && report.getInt(24)==0) refusals++;
                    if (name.startsWith("full-screen") && t==1983.25) {
                        // Invalid inputs are refused and a writable report is zeroed except time_ms.
                        require(analyzer.measure(0,regions,n,report)<0 && report.getDouble(0)==0 && report.getDouble(8)==0 && report.getInt(44)==0);
                        require(analyzer.measure(2000,regions,n-1,report)<0 && report.getDouble(0)==2000 && report.getInt(24)==0);
                        require(analyzer.admit(2000,regions,257,report)<0 && analyzer.admit(2000,null,n,report)<0);
                        require(analyzer.measure(2000,regions,n,report.asReadOnlyBuffer())<0);
                        require(analyzer.measure(2000,regions,n,regions)<0);
                    }
                    break;
                }
                case "rgbframe": {
                    int n=(v.length-3-8)/3;
                    double t=Double.parseDouble(v[1]);
                    if (v[2].equals("1")) require(analyzer.reset()==0);
                    for (int k=0;k<3*n;k++) colors.putDouble(k*8,Double.parseDouble(v[3+k]));
                    require((mode.equals("admit") ? analyzer.admitRgb(t,colors,n,report) : analyzer.measureRgb(t,colors,n,report))==0);
                    int e=3+3*n;
                    require(report.getDouble(0)==t);
                    for (int k=0;k<3;k++) require(report.getInt(24+k*4)==(int)Double.parseDouble(v[e+k]));
                    require(report.getInt(36)==(int)Double.parseDouble(v[e+3]) && report.getInt(40)==(int)Double.parseDouble(v[e+4]));
                    require(report.getDouble(8)==Double.parseDouble(v[e+5]) && report.getDouble(16)==Double.parseDouble(v[e+6]));
                    require(report.getInt(44)==(int)Double.parseDouble(v[e+7]));
                    require(analyzer.measureRgb(t,null,n,report)<0 && analyzer.measureRgb(t,Oscillux.buffer(8),n,report)<0);
                    break;
                }
                case "color": {
                    double[] c=new double[5];
                    for (int k=0;k<5;k++) c[k]=Double.parseDouble(v[1+k]);
                    require(Oscillux.flashRegionFromLinearRgb(c[0],c[1],c[2],regions,3)==0);
                    require(Math.abs(regions.getDouble(48)-c[3])<=tolerance && Math.abs(regions.getDouble(56)-c[4])<=tolerance);
                    break;
                }
                case "invalid": {
                    regions.putDouble(0,0.5); regions.putDouble(8,0.25);
                    require(Oscillux.flashRegionFromLinearRgb(Double.parseDouble(v[1]),Double.parseDouble(v[2]),Double.parseDouble(v[3]),regions,0)<0);
                    require(regions.getDouble(0)==0.5 && regions.getDouble(8)==0.25);
                    break;
                }
                default: require(false);
            }
        }
        if (analyzer!=null) analyzer.close();
        require(Oscillux.flashRegionFromLinearRgb(1,0,0,regions,256)<0 && Oscillux.flashRegionFromLinearRgb(1,0,0,regions.asReadOnlyBuffer(),0)<0);
        require(Oscillux.flashRegionFromLinearRgb(1,0,0,regions,-1)<0 && Oscillux.flashRegionFromLinearRgb(1,0,0,Oscillux.buffer(16),1)<0);
        require(firstExceeds==350 && refusals>0 && cases>=2 && isoCases>=4);
        return cases;
    }
    /** Compares pushed frames with the frame rows of a .frames fixture; returns the row count. */
    static int checkFrames(List<String> expected, ByteBuffer out) {
        int index=0;
        for (String line: expected) {
            if (!line.startsWith("frame ")) continue;
            String[] values=line.split(" ");
            int base=index*Oscillux.dspFrameSize();
            require(out.getLong(base)==Long.parseLong(values[1]));
            require(out.getInt(base+8)==Integer.parseInt(values[2]));
            require(out.getInt(base+12)==24);
            for (int j=3;j<values.length;j++) require(Math.abs(out.getDouble(base+16+(j-3)*8)-Double.parseDouble(values[j])) <= 1e-5);
            index++;
        }
        return index;
    }
    // Ranges of the beat and levels of the default 24-band analyzer in one OscilluxDspFrameExt.
    static void checkBeatAndLevels(ByteBuffer ext, int base) {
        for (int j=56; j<88; j+=8) require(Double.isFinite(ext.getDouble(base+j)));
        double beatPhase=ext.getDouble(base+64), barPhase=ext.getDouble(base+72), confidence=ext.getDouble(base+80);
        require(beatPhase>=0 && beatPhase<1 && barPhase>=0 && barPhase<1 && confidence>=0 && confidence<=1);
        int beat=ext.getInt(base+88), downbeat=ext.getInt(base+92);
        require(beat>=0 && beat<=1 && downbeat>=0 && downbeat<=beat && ext.getInt(base+96)>=0 && ext.getInt(base+96)<4 && ext.getInt(base+100)==0);
        require(ext.getInt(base+104)==24 && ext.getInt(base+108)==0);
        for (int j=112; j<160+24*8; j+=8) require(ext.getDouble(base+j)>=0 && ext.getDouble(base+j)<=1);
        for (int j=160+24*8; j<672; j+=8) require(ext.getDouble(base+j)==0);
    }

    /** Overlay regions (OSC-OVERLAY) through the JNI glue: packing, reduced motion and the analyzer overlay. */
    static void overlay() {
        require(Oscillux.overlayConfigSize()==64 && Oscillux.overlayRegionSize()==64 && Oscillux.flashOverlaySize()==40 && Oscillux.flashOverlayReportSize()==32);
        ByteBuffer config=Oscillux.buffer(64);
        require(Oscillux.overlayConfigDefault(config)<0);
        config.putInt(0,64);
        require(Oscillux.overlayConfigDefault(config.asReadOnlyBuffer())<0 && Oscillux.overlayConfigDefault(config)==0);
        require(config.getInt(12)==255 && config.getDouble(32)==4.5 && config.getDouble(40)==1);
        // A caption: light text and damp flash at full strength over the bottom two rows of a 6 by 6 grid.
        ByteBuffer regions=Oscillux.buffer(9*64);
        double[] caption={0.1,0.8,0.8,0.15,0.01,0,1};
        for (int k=0;k<7;k++) regions.putDouble(k*8,caption[k]);
        regions.putInt(56,1|32);
        ByteBuffer block=Oscillux.buffer(Oscillux.OVERLAY_UNIFORMS_SIZE);
        require(Oscillux.overlayPack(config,regions,1,block,Oscillux.OVERLAY_UNIFORMS_SIZE)==0);
        // Ceiling 1.05 / 4.5 - 0.05 - 1e-4 as conformance/packing/overlay-uniforms.json packs it.
        require(block.getFloat(0)==1f && block.getInt(4)==0x3e3ba185 && block.getFloat(68)==0.8f && block.getFloat(204)==33f);
        require(Oscillux.overlayPack(config,regions,9,block,320)<0 && Oscillux.overlayPack(config,regions,1,block,319)<0 && Oscillux.overlayPack(config,regions,1,block.asReadOnlyBuffer(),320)<0);
        require(Oscillux.overlayPack(config,null,0,block,320)==0 && block.getFloat(0)==0f);
        ByteBuffer intensity=Oscillux.buffer(8), flash=Oscillux.buffer(Oscillux.flashConfigSize());
        flash.putInt(0,Oscillux.flashConfigSize());
        require(Oscillux.flashConfigDefault(flash)==0);
        flash.putInt(4,6); flash.putInt(8,6);
        require(Oscillux.overlayPresentationIntensity(config,intensity)==0 && intensity.getDouble(0)==1);
        config.putInt(4,1);
        require(Oscillux.overlayPresentationIntensity(config,intensity)==0 && intensity.getDouble(0)==0.5);
        require(Oscillux.overlayFlashConfig(config,flash.asReadOnlyBuffer())<0 && Oscillux.overlayFlashConfig(config,flash)==0);
        ByteBuffer tour=Oscillux.buffer(32), vivid=Oscillux.buffer(16);
        require(Oscillux.paletteTour(0,-3,tour)==0 && tour.getDouble(0)==-1 && tour.getDouble(16)==13);
        require(Oscillux.paletteTour(Double.NaN,0,tour)<0 && Oscillux.paletteTour(0,0,Oscillux.buffer(8))<0);
        require(Oscillux.vividPresent(vivid)==0 && vivid.getDouble(0)==1.35 && vivid.getDouble(8)==1.2);
        require(flash.getDouble(40)==1 && flash.getDouble(32)==0.1 && flash.getInt(12)==1);
        ByteBuffer rules=Oscillux.buffer(40), report=Oscillux.buffer(32), samples=Oscillux.buffer(36*16), flashReport=Oscillux.buffer(48);
        rules.putInt(0,40);
        require(Oscillux.flashOverlayDefault(rules)==0 && rules.getDouble(8)==0.05 && rules.getDouble(16)==1 && rules.getDouble(24)==1);
        report.putInt(0,32);
        try (Oscillux.FlashAnalyzer analyzer=new Oscillux.FlashAnalyzer(flash)) {
            require(analyzer.overlayReport(report)==0 && report.getInt(4)==0);
            require(analyzer.setOverlay(rules,regions,1)==0);
            int transitions=0;
            for (int f=0;f<60;f++) {
                // The caption rows flicker by 0.07: below the general 0.1, at or above the overlay's 0.05.
                for (int r=0;r<36;r++) { samples.putDouble(r*16,r>=24 && f%2==1 ? 0.37 : 0.3); samples.putDouble(r*16+8,0); }
                require(analyzer.measure(f*16.75,samples,36,flashReport)==0 && analyzer.overlayReport(report)==0);
                require(report.getInt(4)==1 && report.getInt(16)==12 && flashReport.getInt(28)==0);
                transitions+=report.getInt(8);
            }
            require(transitions>=50 && report.getInt(20)==1);
            rules.putDouble(8,0.2);
            require(analyzer.setOverlay(rules,regions,1)<0 && analyzer.setOverlay(rules,regions,9)<0);
            require(analyzer.setOverlay(null,null,0)==0 && analyzer.measure(60*16.75,samples,36,flashReport)==0);
            require(analyzer.overlayReport(report)==0 && report.getInt(4)==0 && report.getInt(16)==0);
            report.putInt(0,28);
            require(analyzer.overlayReport(report)<0 && analyzer.overlayReport(report.asReadOnlyBuffer())<0);
        }
    }
    static String sha256(ByteBuffer bytes) throws Exception {
        java.security.MessageDigest md=java.security.MessageDigest.getInstance("SHA-256");
        md.update(bytes.duplicate().clear());
        StringBuilder hex=new StringBuilder();
        for (byte b: md.digest()) hex.append(String.format("%02x",b&0xff));
        return hex.toString();
    }
    /**
     * Seeks through conformance/cdg/mixed.cdg and karaoke-tiles.cdg in the order of their
     * .expect files (written by the independent oracle tools/cdg-vectors.py) and checks every
     * state, window digest and index count through the Cdg binding; returns the number of
     * checked lines.
     */
    static int cdg() throws Exception {
        require(Oscillux.cdgStateSize()==192);
        ByteBuffer state=Oscillux.buffer(192), screen=Oscillux.buffer(Oscillux.Cdg.SCREEN_PIXELS), rgba=Oscillux.buffer(Oscillux.Cdg.WINDOW_RGBA_BYTES);
        ByteBuffer counts=Oscillux.buffer(4*Oscillux.Cdg.INDEX_COUNT);
        int checked=0;
        for (String name: new String[]{"mixed","karaoke-tiles"}) {
            byte[] bytes=Files.readAllBytes(Path.of("conformance/cdg/"+name+".cdg"));
            ByteBuffer packs=Oscillux.buffer(bytes.length).put(bytes);
            try (Oscillux.Cdg cdg=new Oscillux.Cdg(packs,bytes.length)) {
                state.putInt(0,0);
                require(cdg.state(state)<0);
                state.putInt(0,192);
                require(cdg.state(state)==0 && state.getLong(176)==0 && state.getLong(184)==bytes.length/24);
                require(cdg.advanceToPack(-1)<0 && cdg.advanceToTime(Double.NaN)<0);
                require(cdg.screen(Oscillux.buffer(Oscillux.Cdg.SCREEN_PIXELS-1))<0 && cdg.screen(screen.asReadOnlyBuffer())<0);
                require(cdg.windowRgba(Oscillux.Cdg.KEY_INDEX,16,rgba)<0 && cdg.windowRgba(5,0,rgba)<0 && cdg.windowRgba(Oscillux.Cdg.KEY_MASK,0x10000,rgba)<0);
                require(cdg.indexCounts(2,counts)<0 && cdg.indexCounts(Oscillux.Cdg.REGION_EDGE,Oscillux.buffer(4*Oscillux.Cdg.INDEX_COUNT-4))<0 && cdg.indexCounts(Oscillux.Cdg.REGION_EDGE,counts.asReadOnlyBuffer())<0);
                require(cdg.advanceToTime(1.0)==0 && cdg.state(state)==0 && state.getLong(176)==301);
                for (String line: Files.readAllLines(Path.of("conformance/cdg/"+name+".expect"))) {
                    String[] v=line.split(" ");
                    if (!v[0].equals("state") && !v[0].equals("rgba") && !v[0].equals("counts")) continue;
                    require(cdg.advanceToPack(Long.parseLong(v[1]))==0 && cdg.state(state)==0 && state.getLong(176)==Long.parseLong(v[1]));
                    if (v[0].equals("state")) {
                        require(cdg.screen(screen)==0 && sha256(screen).equals(v[2]));
                        StringBuilder palette=new StringBuilder(), transparent=new StringBuilder();
                        for (int i=0;i<16;i++) { palette.append(String.format("%03x",state.getInt(48+4*i))); transparent.append(String.format("%02x",state.getInt(112+4*i))); }
                        require(palette.toString().equals(v[3]) && transparent.toString().equals(v[4]));
                        require(state.getInt(4)==Integer.parseInt(v[5]) && state.getInt(8)==Integer.parseInt(v[6]) && state.getInt(20)==Integer.parseInt(v[7]) && state.getInt(24)==Integer.parseInt(v[8]));
                        require(state.getInt(12)==6+state.getInt(4) && state.getInt(16)==12+state.getInt(8));
                    } else if (v[0].equals("counts")) {
                        require(cdg.indexCounts(v[2].equals("edge")?Oscillux.Cdg.REGION_EDGE:Oscillux.Cdg.REGION_WINDOW,counts)==0);
                        StringBuilder got=new StringBuilder();
                        for (int i=0;i<16;i++) got.append(i==0?"":",").append(counts.getInt(4*i));
                        require(got.toString().equals(v[3]));
                    } else {
                        int mode, index=0;
                        if (v[2].equals("none")) mode=Oscillux.Cdg.KEY_NONE;
                        else if (v[2].equals("table")) mode=Oscillux.Cdg.KEY_TRANSPARENT_TABLE;
                        else if (v[2].equals("preset")) mode=Oscillux.Cdg.KEY_PRESET_COLOUR;
                        else if (v[2].startsWith("mask:")) { mode=Oscillux.Cdg.KEY_MASK; index=Integer.parseInt(v[2].substring(5),16); }
                        else { mode=Oscillux.Cdg.KEY_INDEX; index=Integer.parseInt(v[2].substring(6)); }
                        require(cdg.windowRgba(mode,index,rgba)==0 && sha256(rgba).equals(v[3]));
                    }
                    checked++;
                }
            }
        }
        return checked;
    }
    public static void main(String[] args) throws Exception {
        require(Oscillux.abiVersion() == 1);
        require(Oscillux.version() >= 0);
        ByteBuffer cfg = Oscillux.buffer(Oscillux.dspConfigSize());
        require(Oscillux.dspConfigDefault(cfg) == 0);
        require(Oscillux.dspConfigDefault(cfg.asReadOnlyBuffer()) < 0);
        byte[] wav = Files.readAllBytes(Path.of("conformance/dsp/sine-440.wav"));
        ByteBuffer wave = ByteBuffer.wrap(wav).order(ByteOrder.LITTLE_ENDIAN);
        int start=12, length=0;
        while (start+8 <= wav.length) {
            int size=wave.getInt(start+4);
            if (wave.getInt(start) == 0x61746164) { start+=8; length=size; break; }
            start+=8+size+(size%2);
        }
        require(length > 0);
        ByteBuffer pcm=Oscillux.buffer(length*2);
        for (int i=0; i<length/2; i++) pcm.putFloat(i*4, wave.getShort(start+i*2)/32768.0f);
        ByteBuffer out=Oscillux.buffer(Oscillux.dspFrameSize()*64), result=Oscillux.buffer(16);
        List<String> expected=Files.readAllLines(Path.of("conformance/dsp/sine-440.frames"));
        try (Oscillux.Dsp dsp = new Oscillux.Dsp(cfg)) {
            require(dsp.beginSegment(0, false)==0);
            require(dsp.push(pcm,length/2,1,out.asReadOnlyBuffer(),64,result)<0);
            require(dsp.push(pcm,length/2,1,out,64,result.asReadOnlyBuffer())<0);
            require(dsp.push(pcm.asReadOnlyBuffer(),length/2,1,out,64,result)==0);
            int index=checkFrames(expected, out);
            require(result.getLong(0)==length/2 && result.getLong(8)==index);
            require(dsp.push(ByteBuffer.allocate(4),1,1,out,64,result)<0);
            require(dsp.push(pcm,-1,1,out,64,result)<0);
        }
        ByteBuffer policy=Oscillux.buffer(32), in=Oscillux.buffer(56), limited=Oscillux.buffer(56);
        require(Oscillux.limiterPolicyDefault(policy)==0);
        require(Oscillux.limiterPolicyDefault(policy.asReadOnlyBuffer())<0);
        policy.putDouble(8,0.35); policy.putDouble(16,0.2);
        try (Oscillux.Limiter limiter=new Oscillux.Limiter(policy)) {
            in.putDouble(8,0.8); in.putDouble(48,1);
            require(limiter.process(in,limited.asReadOnlyBuffer())<0);
            require(limiter.process(in.asReadOnlyBuffer(),limited)==0);
            require(limited.getDouble(8)==0.35);
            require(limiter.process(ByteBuffer.allocate(56),limited)<0);
            require(limiter.reset()==0);
        }
        require(Oscillux.limiterPolicySize()==32 && Oscillux.limiterFrameSize()==56);
        require(Oscillux.statusString(-2).equals("invalid argument") && Oscillux.statusString(42).equals("unknown status"));
        require(Oscillux.dspConfigValidate(cfg)==null);
        ByteBuffer bad=Oscillux.buffer(Oscillux.dspConfigSize());
        require(Oscillux.dspConfigDefault(bad)==0);
        bad.putInt(4,3);
        require("fft_window_samples".equals(Oscillux.dspConfigValidate(bad)));
        require(Oscillux.dspConfigValidate(ByteBuffer.allocate(4))!=null);
        int frameSize=Oscillux.dspFrameSize(), frames=0;
        for (String line: expected) if (line.startsWith("frame ")) frames++;
        // Float64 PCM of the same samples matches the float32 path.
        ByteBuffer pcm64=Oscillux.buffer(length*4), out64=Oscillux.buffer(frameSize*64);
        for (int i=0; i<length/2; i++) pcm64.putDouble(i*8, pcm.getFloat(i*4));
        try (Oscillux.Dsp dsp = new Oscillux.Dsp(cfg)) {
            require(dsp.beginSegment(0, false)==0);
            require(dsp.pushF64(pcm64,length/2,1,out64,64,result)==0);
            require(result.getLong(8)==frames);
            require(dsp.pushF64(pcm64,length/2,1,pcm64,64,result)<0);
            for (int i=0; i<frames; i++) {
                int base=i*frameSize;
                require(out64.getLong(base)==out.getLong(base) && out64.getInt(base+8)==out.getInt(base+8));
                for (int j=16; j<frameSize; j+=8) require(Math.abs(out64.getDouble(base+j)-out.getDouble(base+j)) <= 1e-9);
            }
        }
        // The versioned config defaults to behaviour version 2 (conformance/dsp/v2); version 1
        // through it matches the ABI-1 frames.
        int versionedSize=Oscillux.dspVersionedConfigSize();
        ByteBuffer versioned=Oscillux.buffer(versionedSize), outV=Oscillux.buffer(frameSize*64);
        require(versionedSize==144 && Oscillux.dspVersionedConfigDefault(versioned)<0);
        versioned.putInt(0,versionedSize);
        versioned.putInt(140,7);
        require(Oscillux.dspVersionedConfigDefault(versioned)==0 && versioned.getInt(136)==2 && versioned.getInt(140)==0);
        require(Oscillux.dspVersionedConfigValidate(versioned)==null);
        List<String> expectedV2=Files.readAllLines(Path.of("conformance/dsp/v2/sine-440.frames"));
        for (int version=2; version>=1; version--) {
            versioned.putInt(136,version);
            try (Oscillux.Dsp dsp=Oscillux.Dsp.createVersioned(versioned)) {
                require(dsp.beginSegment(0, false)==0);
                require(dsp.push(pcm,length/2,1,outV,64,result)==0);
                require(result.getLong(8)==checkFrames(version==2 ? expectedV2 : expected, outV));
            }
        }
        versioned.putInt(136,5);
        require("behavior_version".equals(Oscillux.dspVersionedConfigValidate(versioned)));
        try { Oscillux.Dsp.createVersioned(versioned).close(); require(false); } catch (IllegalArgumentException refused) { }
        versioned.putInt(136,2); versioned.putInt(140,1);
        require("reserved".equals(Oscillux.dspVersionedConfigValidate(versioned)));
        try { Oscillux.Dsp.createVersioned(versioned).close(); require(false); } catch (IllegalArgumentException refused) { }
        versioned.putInt(140,0); versioned.putInt(0,versionedSize-8);
        require("struct_size".equals(Oscillux.dspVersionedConfigValidate(versioned)));
        require(Oscillux.dspVersionedConfigValidate(ByteBuffer.allocate(4))!=null);
        // DSP -> mapping -> packing over the analyzed sine frames.
        ByteBuffer mapping=Oscillux.buffer(Oscillux.mappingConfigSize()), mapped=Oscillux.buffer(Oscillux.mappedSize());
        require(Oscillux.mappingConfigDefault(mapping)==0);
        require(Oscillux.mappingConfigFromDsp(bad, mapping)<0);
        require(Oscillux.mappingConfigFromDsp(cfg, mapping.asReadOnlyBuffer())<0);
        require(Oscillux.mappingConfigFromDsp(cfg, mapping)==0);
        int fieldSize=Oscillux.uniformFieldSize();
        ByteBuffer fields=Oscillux.buffer(fieldSize*3);
        int[][] layout={{0,0,9,0,4},{1,0,64,48,4},{2,0,2,320,16}};
        for (int f=0; f<3; f++) for (int k=0; k<5; k++) fields.putInt(f*fieldSize+k*4, layout[f][k]);
        ByteBuffer host=Oscillux.buffer(16), block=Oscillux.buffer(352);
        host.putDouble(0,0.25); host.putDouble(8,0.5);
        try (Oscillux.Mapper mapper=new Oscillux.Mapper(mapping); Oscillux.Packer packer=new Oscillux.Packer(fields,3,352)) {
            double reference=mapping.getDouble(0), floor=mapping.getDouble(8);
            for (int i=0; i<frames; i++) {
                require(mapper.process(out,i,false,mapped)==0);
                double rms=out.getDouble(i*frameSize+24), loudness=out.getDouble(i*frameSize+32);
                double amplitude=rms>0 ? Math.min(1, Math.max(0, (loudness+reference-floor)/-floor)) : 0;
                require(Math.abs(mapped.getDouble(0)-amplitude) <= 1e-12);
                for (int j=0; j<9; j++) require(mapped.getDouble(j*8)>=0 && mapped.getDouble(j*8)<=1);
                require(packer.pack(mapped,host,2,block,352)==0);
                for (int j=0; j<9; j++) require(block.getFloat(j*4)==(float)mapped.getDouble(j*8));
                for (int k=0; k<64; k++) require(block.getFloat(48+k*4)==mapped.getFloat(72+k*4));
                require(block.getFloat(320)==0.25f && block.getFloat(336)==0.5f);
                for (int[] gap: new int[][]{{36,48},{304,320},{324,336},{340,352}}) for (int b=gap[0]; b<gap[1]; b++) require(block.get(b)==0);
            }
            require(mapper.process(out,0,true,mapped)==0);
            for (int j=0; j<9; j++) require(mapped.getDouble(j*8)==0);
            require(mapper.process(out,64,false,mapped)<0);
            require(mapper.process(out,0,false,mapped.asReadOnlyBuffer())<0);
            require(mapper.reset()==0);
            require(packer.pack(mapped,host,2,block,351)<0);
            require(packer.pack(mapped,host,2,block.asReadOnlyBuffer(),352)<0);
            require(packer.pack(mapped,null,0,block,352)<0 && packer.pack(mapped,host,1,block,352)<0);
        }
        // pushExt: the frames equal push's, every ext element is stamped and carries the
        // descriptors (from 8), beat (from 56) and levels (from 104), and Mapper.processExt
        // reads FLUX and CENTROID from the descriptors.
        int extSize=Oscillux.dspFrameExtSize();
        ByteBuffer outE=Oscillux.buffer(frameSize*64), ext=Oscillux.buffer(extSize*64);
        require(extSize==672);
        try (Oscillux.Dsp dsp=new Oscillux.Dsp(cfg)) {
            require(dsp.beginSegment(0, false)==0);
            require(dsp.pushExt(pcm,length/2,1,outE,ext.asReadOnlyBuffer(),64,result)<0);
            require(dsp.pushExt(pcm,length/2,1,outE,outE,64,result)<0);
            require(dsp.pushExt(pcm,length/2,1,outE,Oscillux.buffer(extSize*63),64,result)<0);
            require(dsp.pushExt(pcm,length/2,1,outE,ext,64,result)==0);
            require(result.getLong(0)==length/2 && result.getLong(8)==frames);
            for (int b=0; b<frames*frameSize; b++) require(outE.get(b)==out.get(b));
            for (int i=0; i<frames; i++) {
                require(ext.getInt(i*extSize)==extSize && ext.getInt(i*extSize+4)==0);
                for (int j=8; j<56; j+=8) require(Double.isFinite(ext.getDouble(i*extSize+j)));
                checkBeatAndLevels(ext, i*extSize);
            }
            double centroid=ext.getDouble((frames-1)*extSize+40);
            require(Math.abs(centroid-440)<=0.02*440 && ext.getDouble(48)==0);
        }
        ByteBuffer ext64=Oscillux.buffer(extSize*64);
        try (Oscillux.Dsp dsp=new Oscillux.Dsp(cfg)) {
            require(dsp.beginSegment(0, false)==0);
            require(dsp.pushExtF64(pcm64,length/2,1,out64,ext64,64,result)==0 && result.getLong(8)==frames);
            for (int i=0; i<frames*extSize; i+=8) {
                int at=i%extSize;
                if (at==0 || at==88 || at==96 || at==104) require(ext64.getLong(i)==ext.getLong(i));
                else require(Math.abs(ext64.getDouble(i)-ext.getDouble(i)) <= 1e-9);
            }
        }
        // A 120 BPM train of decaying noise clicks, pushed a second at a time, brings the beat
        // tracker's tempo and beats out through pushExt.
        // Every hop is also mapped and queued, with its beat, on a reaction sampler.
        ByteBuffer reactionConfig=Oscillux.buffer(Oscillux.reactionConfigSize()), reaction=Oscillux.buffer(Oscillux.reactionSize());
        require(Oscillux.reactionConfigDefault(1, cfg.getInt(0), reactionConfig)<0);
        reactionConfig.putInt(0, Oscillux.reactionConfigSize());
        require(Oscillux.reactionConfigDefault(99, cfg.getInt(0), reactionConfig)<0);
        require(Oscillux.reactionConfigDefault(1, cfg.getInt(0), reactionConfig)==0 && reactionConfig.getInt(4)==256);
        reactionConfig.putInt(4, 4096);
        try (Oscillux.Dsp dsp=new Oscillux.Dsp(cfg); Oscillux.Mapper clickMapper=new Oscillux.Mapper(mapping); Oscillux.ReactionSampler sampler=new Oscillux.ReactionSampler(reactionConfig)) {
            int rate=cfg.getInt(0), chunk=rate, period=rate/2, seed=1, beats=0, hops=0;
            double tempo=0;
            ByteBuffer clickMapped=Oscillux.buffer(Oscillux.mappedSize());
            ByteBuffer clicks=Oscillux.buffer(chunk*4), clickOut=Oscillux.buffer(frameSize*128), clickExt=Oscillux.buffer(extSize*128);
            require(dsp.beginSegment(0, false)==0);
            for (int at=0; at<12*rate; at+=chunk) {
                for (int i=0; i<chunk; i++) {
                    int t=(at+i)%period;
                    seed=seed*1664525+1013904223;
                    clicks.putFloat(i*4, t<480 ? (float)(0.8*(1-t/480.0)*((seed&0xffffffffL)/2147483648.0-1)) : 0f);
                }
                require(dsp.pushExt(clicks,chunk,1,clickOut,clickExt,128,result)==0 && result.getLong(0)==chunk);
                for (int i=0; i<result.getLong(8); i++) {
                    checkBeatAndLevels(clickExt, i*extSize);
                    tempo=clickExt.getDouble(i*extSize+56);
                    beats+=clickExt.getInt(i*extSize+88);
                    require(clickMapper.processExt(clickOut, clickExt, (int)i, false, clickMapped)==0);
                    require(sampler.push(clickOut.getDouble(i*frameSize+16), clickMapped, clickExt, (int)i)==0);
                    hops++;
                }
            }
            require(Math.abs(tempo-120)<=0.04*120 && beats>=12);
            require(sampler.queued()==hops && sampler.push(Double.NaN, clickMapped, null, 0)<0 && sampler.push(1e9, clickMapped, clickExt, 128)<0);
            require(sampler.sample(0, reaction.asReadOnlyBuffer())<0 && sampler.sample(Double.POSITIVE_INFINITY, reaction)<0);
            boolean locked=false;
            for (int k=0; k<60*11; k++) {
                require(sampler.sample(k*1000.0/60, reaction)==0);
                double phase=reaction.getDouble(344);
                require(phase>=0 && phase<1 && reaction.getDouble(328)>=0 && reaction.getDouble(328)<=1);
                locked|=reaction.getInt(388)==1;
            }
            require(locked && sampler.queued()<hops);
            ByteBuffer clock=Oscillux.buffer(Oscillux.beatClockSize());
            clock.putDouble(0, 11000).putDouble(8, 90).putLong(32, 7).putInt(40, 4);
            require(sampler.setBeatClock(clock)==0);
            for (int k=0; k<=60; k++) require(sampler.sample(k==60 ? 12000 : 11000+k*1000.0/60, reaction)==0);
            // Taken at once (tempo, lock, count); the phase slews onto the clock: 1.5 beats after beat 7.
            require(reaction.getDouble(360)==90 && reaction.getLong(376)==8 && reaction.getInt(388)==1 && Math.abs(reaction.getDouble(344)-0.5)<5e-3);
            clock.putInt(40, 0);
            require(sampler.setBeatClock(clock)<0 && sampler.setBeatClock(null)==0);
            require(sampler.reset()==0 && sampler.queued()==0);
        }
        try (Oscillux.Mapper plain=new Oscillux.Mapper(mapping); Oscillux.Mapper withExt=new Oscillux.Mapper(mapping)) {
            ByteBuffer mappedExt=Oscillux.buffer(Oscillux.mappedSize());
            for (int i=0; i<frames; i++) {
                require(plain.process(out,i,false,mapped)==0);
                require(withExt.processExt(out,null,i,false,mappedExt)==0);
                for (int b=0; b<Oscillux.mappedSize(); b++) require(mapped.get(b)==mappedExt.get(b));
                require(mapped.getDouble(56)==mapped.getDouble(40)); // without descriptors FLUX keeps the onset proxy
            }
            require(withExt.reset()==0);
            int last=frames-1;
            for (int i=0; i<frames; i++) require(withExt.processExt(out,ext,i,false,mappedExt)==0);
            double flux=ext.getDouble(last*extSize+48), hz=ext.getDouble(last*extSize+40);
            require(mappedExt.getDouble(56)==Math.min(1, Math.max(0, flux)));
            require(Math.abs(mappedExt.getDouble(64)-Math.min(1, Math.log10(hz/20)/3)) <= 1e-12);
            require(withExt.processExt(out,ext,64,false,mappedExt)<0);
            require(withExt.processExt(out,Oscillux.buffer(extSize),1,false,mappedExt)<0);
        }
        // The relative level source maps BASS, MID, TREBLE and the spectrum from the ext levels
        // (relative bands from byte 160) and leaves every other slot on the frame.
        try (Oscillux.Mapper absolute=new Oscillux.Mapper(mapping); Oscillux.Mapper relative=new Oscillux.Mapper(mapping)) {
            ByteBuffer mappedRel=Oscillux.buffer(Oscillux.mappedSize());
            require(relative.setLevelSource(2)<0 && relative.setLevelSource(-1)<0);
            require(relative.setLevelSource(Oscillux.Mapper.LEVELS_RELATIVE)==0);
            require(relative.process(out,0,false,mappedRel)<0);
            require(relative.processExt(out,null,0,false,mappedRel)<0);
            for (int i=0; i<frames; i++) {
                require(absolute.processExt(out,ext,i,false,mapped)==0);
                require(relative.processExt(out,ext,i,false,mappedRel)==0);
                for (int slot : new int[]{0,1,5,6,7,8}) require(mapped.getDouble(slot*8)==mappedRel.getDouble(slot*8));
                for (int slot=2; slot<5; slot++) require(mappedRel.getDouble(slot*8)>=0 && mappedRel.getDouble(slot*8)<=1);
                require(mappedRel.getFloat(72)==(float)Math.min(1, Math.max(0, ext.getDouble(i*extSize+160))));
            }
            require(relative.setLevelSource(Oscillux.Mapper.LEVELS_ABSOLUTE)==0);
            require(absolute.reset()==0 && relative.reset()==0);
            for (int i=0; i<frames; i++) {
                require(absolute.processExt(out,ext,i,false,mapped)==0);
                require(relative.processExt(out,ext,i,false,mappedRel)==0);
                for (int b=0; b<Oscillux.mappedSize(); b++) require(mapped.get(b)==mappedRel.get(b));
            }
        }
        require(Oscillux.curveConfigSize()==120 && Oscillux.curveInputSize()==48);
        ByteBuffer curveConfig=Oscillux.buffer(120), curveInput=Oscillux.buffer(48), value=Oscillux.buffer(8);
        require(Oscillux.curveConfigDefault(curveConfig)==0);
        curveConfig.putInt(0,1); curveConfig.putInt(4,1); curveConfig.putInt(8,3); curveConfig.putInt(16,6);
        curveConfig.putDouble(32,0); curveConfig.putDouble(40,1); curveConfig.putDouble(48,2);
        curveInput.putDouble(0,0.5);
        try (Oscillux.Curve curve=new Oscillux.Curve(curveConfig)) {
            require(curve.evaluate(curveInput,value)==0 && value.getDouble(0)==0.125);
            require(curve.evaluate(curveInput,value.asReadOnlyBuffer())<0);
        }
        ByteBuffer governorConfig=Oscillux.buffer(Oscillux.governorConfigSize()), stats=Oscillux.buffer(Oscillux.governorStatsSize());
        require(Oscillux.governorConfigDefault(governorConfig)==0);
        try (Oscillux.Governor governor=new Oscillux.Governor(governorConfig)) {
            require(governor.record(Double.NaN,stats)==0 && stats.getInt(16)==3 && stats.getInt(20)==0);
            for (int i=0; i<10; i++) require(governor.record(33.4,stats)==0);
            require(stats.getInt(16)==3 && stats.getInt(20)==1 && Math.abs(stats.getDouble(0)-33.4) <= 1e-9);
            require(governor.reset(1)==0 && governor.reset(-1)<0);
            require(governor.record(Double.NaN,stats)==0 && stats.getInt(16)==1 && stats.getInt(20)==0);
            require(governor.record(16,stats.asReadOnlyBuffer())<0);
        }
        // Transition scheduler: no confident beat, so the blend starts after the 0.5 s pre-roll
        // and lasts the 1.6 s fallback, and the last blended update reads p = 1 exactly.
        require(Oscillux.transitionConfigSize()==48 && Oscillux.transitionClockSize()==40 && Oscillux.transitionStatusSize()==48);
        ByteBuffer transitionConfig=Oscillux.buffer(Oscillux.transitionConfigSize()), clock=Oscillux.buffer(Oscillux.transitionClockSize()), status=Oscillux.buffer(Oscillux.transitionStatusSize());
        require(Oscillux.transitionConfigDefault(transitionConfig)<0);
        transitionConfig.putInt(0,Oscillux.transitionConfigSize());
        require(Oscillux.transitionConfigDefault(transitionConfig)==0 && transitionConfig.getInt(8)==4);
        try (Oscillux.Transition transition=new Oscillux.Transition(transitionConfig)) {
            clock.putDouble(0,10);
            require(transition.request(clock,0,0,status)==0 && status.getDouble(16)==10.5 && status.getDouble(24)==10.5+1.6 && status.getInt(32)==1);
            clock.putDouble(0,11.3);
            require(transition.update(clock,status)==0 && status.getInt(32)==3 && Math.abs(status.getDouble(0)-0.5)<=1e-12);
            clock.putDouble(0,12.2);
            require(transition.update(clock,status)==0 && status.getInt(32)==4 && status.getDouble(0)==1.0);
            require(transition.status(10.4,status)==0 && status.getDouble(0)==0.0 && status.getInt(32)==1);
            require(transition.request(clock,3,0,status)<0 && transition.request(clock,-1,0,status)<0 && transition.update(clock,status.asReadOnlyBuffer())<0);
            require(transition.reset()==0 && transition.status(11,status)==0 && status.getInt(32)==0);
        }
        transitionConfig.putInt(8,0);
        try { new Oscillux.Transition(transitionConfig); require(false); } catch (IllegalArgumentException refusedConfig) {}
        // An offline beat grid of a 20 s mono 120 BPM click train in 4/4.
        require(Oscillux.beatGridConfigSize()==32 && Oscillux.beatGridInfoSize()==48 && Oscillux.beatGridBeatSize()==24 && Oscillux.beatGridClockSize()==40);
        ByteBuffer gridConfig=Oscillux.buffer(32), gridInfo=Oscillux.buffer(48), gridClock=Oscillux.buffer(40);
        require(Oscillux.beatGridConfigDefault(gridConfig)<0);
        gridConfig.putInt(0,32);
        require(Oscillux.beatGridConfigDefault(gridConfig.asReadOnlyBuffer())<0);
        require(Oscillux.beatGridConfigDefault(gridConfig)==0 && Oscillux.beatGridConfigValidate(gridConfig)==null);
        require(gridConfig.getInt(4)==44100 && gridConfig.getInt(8)==2 && gridConfig.getDouble(16)==40 && gridConfig.getDouble(24)==240);
        gridConfig.putInt(8,0);
        require("channels".equals(Oscillux.beatGridConfigValidate(gridConfig)));
        gridConfig.putInt(8,1);
        int gridRate=44100, gridFrames=20*gridRate;
        ByteBuffer gridPcm=Oscillux.buffer(gridFrames*4);
        for (int onset=0, index=0; onset<gridFrames; onset+=gridRate/2, index++) {
            double freq=index%4==0 ? 2000 : 1000, amp=index%4==0 ? 0.8 : 0.5;
            for (int n=0; n<(int)(0.03*gridRate) && onset+n<gridFrames; n++) {
                double t=n/(double)gridRate;
                gridPcm.putFloat((onset+n)*4, (float)(amp*Math.exp(-t/0.008)*Math.sin(2*Math.PI*freq*t)));
            }
        }
        try { new Oscillux.BeatGrid(gridConfig, Oscillux.buffer(16), 5).close(); require(false); } catch (IllegalArgumentException refused) { }
        try (Oscillux.BeatGrid grid=new Oscillux.BeatGrid(gridConfig, gridPcm, gridFrames)) {
            int count=grid.beatCount();
            require(count>=36 && count<=41);
            require(grid.info(gridInfo)==0 && gridInfo.getLong(0)==count && gridInfo.getInt(40)==4);
            require(Math.abs(gridInfo.getDouble(16)-120)<=0.01*120 && Math.abs(gridInfo.getDouble(32)-20)<=1e-9);
            require(grid.info(gridInfo.asReadOnlyBuffer())<0);
            ByteBuffer gridBeats=Oscillux.buffer(24*count);
            require(grid.copyBeats(0,gridBeats.asReadOnlyBuffer(),count)<0 && grid.copyBeats(count+1,gridBeats,count)<0);
            require(grid.copyBeats(0,gridBeats,count)==count && grid.copyBeats(count,gridBeats,count)==0 && grid.copyBeats(count-1,gridBeats,count)==1);
            require(grid.copyBeats(0,gridBeats,count)==count);
            for (int i=0; i<count; i++) {
                double at=gridBeats.getDouble(i*24);
                require(Math.abs(at-Math.rint(at*2)/2)<=0.01);
                if (i>0) require(at>gridBeats.getDouble((i-1)*24));
                require(gridBeats.getInt(i*24+16)==(gridBeats.getInt(16)+i)%4);
            }
            double mid=0.5*(gridBeats.getDouble(10*24)+gridBeats.getDouble(11*24));
            require(grid.clock(mid,gridClock)==0 && gridClock.getLong(24)==10 && Math.abs(gridClock.getDouble(0)-0.5)<=1e-9);
            require(gridClock.getInt(32)==gridBeats.getInt(10*24+16));
            require(grid.clock(Double.NaN,gridClock)<0 && gridClock.getLong(24)==-1);
            require(grid.clock(mid,gridClock.asReadOnlyBuffer())<0);
        }
        int flashCases=regionFlash(Path.of(args[0]));
        overlay();
        int cdgLines=cdg();
        System.out.println("JNI adapter DSP pinned sine fixture (behaviour versions 1 and 2), float64 PCM, pushExt descriptors, beat and levels (a 120 BPM click train) through the reaction sampler, Mapper.processExt and the relative level source, DSP-mapping-packing pipeline, curve, governor, transition scheduler, the offline beat grid (a 120 BPM click train), limiter clamp, "+flashCases+" region flash cases, "+cdgLines+" CD+G oracle lines, overlay packing, reduced motion and the analyzer overlay and invalid buffers passed");
    }
}
