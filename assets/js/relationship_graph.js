// Relationship Graph - D3 Force-Directed Layout
// Shows connections between main process, sub-agents, coding agents, and system processes

export const RelationshipGraph = {
  mounted() {
    this.initGraph();
    this.handleEvent("graph_update", (data) => this.updateGraph(data));
  },

  initGraph() {
    const container = this.el;
    const width = container.clientWidth || 600;
    const height = 300;

    // Clear any existing SVG
    container.innerHTML = '';

    // Create SVG
    this.svg = document.createElementNS("http://www.w3.org/2000/svg", "svg");
    this.svg.setAttribute("width", "100%");
    this.svg.setAttribute("height", height);
    this.svg.setAttribute("viewBox", `0 0 ${width} ${height}`);
    this.svg.style.background = "transparent";
    container.appendChild(this.svg);

    // Create groups for links and nodes
    this.linksGroup = document.createElementNS("http://www.w3.org/2000/svg", "g");
    this.nodesGroup = document.createElementNS("http://www.w3.org/2000/svg", "g");
    this.labelsGroup = document.createElementNS("http://www.w3.org/2000/svg", "g");
    this.svg.appendChild(this.linksGroup);
    this.svg.appendChild(this.nodesGroup);
    this.svg.appendChild(this.labelsGroup);

    this.width = width;
    this.height = height;
    this.nodes = [];
    this.links = [];
    this.simulation = null;
  },

  updateGraph(data) {
    const { nodes, links } = data;
    const width = this.width;
    const height = this.height;
    
    // Preserve existing positions for nodes that already exist
    const existingPositions = {};
    this.nodes.forEach(n => {
      existingPositions[n.id] = { x: n.x, y: n.y };
    });
    
    // Update nodes, keeping existing positions
    this.nodes = nodes.map((n, i) => {
      if (existingPositions[n.id]) {
        return { ...n, x: existingPositions[n.id].x, y: existingPositions[n.id].y };
      } else {
        // New node - position it based on type
        const pos = this.getInitialPosition(n, i, nodes.length);
        return { ...n, x: pos.x, y: pos.y };
      }
    });
    
    this.links = links.map(l => ({...l}));

    // Only run simulation if there are new nodes
    const hasNewNodes = nodes.some(n => !existingPositions[n.id]);
    
    if (hasNewNodes || this.nodes.length === 0) {
      if (this.simulation) {
        this.simulation.stop();
      }
      this.simulation = this.createSimulation();
    } else {
      // Just re-render with existing positions
      this.render();
    }
  },

  getInitialPosition(node, index, total) {
    const width = this.width;
    const height = this.height;
    const centerX = width / 2;
    const centerY = height / 2;
    
    if (node.type === 'main') {
      return { x: centerX, y: centerY };
    }
    
    // Position based on type in different arcs
    const typeOffsets = {
      'subagent': { startAngle: -2.4, endAngle: -0.7, radius: 110 },
      'coding_agent': { startAngle: -0.5, endAngle: 0.5, radius: 120 },
      'system': { startAngle: 0.7, endAngle: 2.4, radius: 100 }
    };
    
    const config = typeOffsets[node.type] || { startAngle: 0, endAngle: Math.PI * 2, radius: 100 };
    
    // Find how many nodes of this type and this node's index within that type
    const angle = config.startAngle + (config.endAngle - config.startAngle) * Math.random();
    
    return {
      x: centerX + config.radius * Math.cos(angle),
      y: centerY + config.radius * Math.sin(angle)
    };
  },

  createSimulation() {
    const width = this.width;
    const height = this.height;
    const nodes = this.nodes;
    const links = this.links;
    const centerX = width / 2;
    const centerY = height / 2;

    // Fix main node at center
    const mainNode = nodes.find(n => n.type === 'main');
    if (mainNode) {
      mainNode.x = centerX;
      mainNode.y = centerY;
      mainNode.fx = centerX;
      mainNode.fy = centerY;
    }

    // Group nodes by type
    const subagents = nodes.filter(n => n.type === 'subagent');
    const codingAgents = nodes.filter(n => n.type === 'coding_agent');
    const systemProcs = nodes.filter(n => n.type === 'system');

    // Position sub-agents in upper arc (only if not already positioned away from center)
    subagents.forEach((node, i) => {
      const distFromCenter = Math.sqrt(Math.pow(node.x - centerX, 2) + Math.pow(node.y - centerY, 2));
      if (distFromCenter < 50) {  // Too close to center, reposition
        const startAngle = -Math.PI * 0.8;
        const endAngle = -Math.PI * 0.2;
        const angle = subagents.length === 1 
          ? (startAngle + endAngle) / 2
          : startAngle + (endAngle - startAngle) * (i / Math.max(subagents.length - 1, 1));
        node.x = centerX + 110 * Math.cos(angle);
        node.y = centerY + 110 * Math.sin(angle);
      }
    });

    // Position coding agents on the right
    codingAgents.forEach((node, i) => {
      const distFromCenter = Math.sqrt(Math.pow(node.x - centerX, 2) + Math.pow(node.y - centerY, 2));
      if (distFromCenter < 50) {
        const startAngle = -Math.PI * 0.2;
        const endAngle = Math.PI * 0.2;
        const angle = codingAgents.length === 1
          ? 0
          : startAngle + (endAngle - startAngle) * (i / Math.max(codingAgents.length - 1, 1));
        node.x = centerX + 120 * Math.cos(angle);
        node.y = centerY + 120 * Math.sin(angle);
      }
    });

    // Position system processes in lower arc
    systemProcs.forEach((node, i) => {
      const distFromCenter = Math.sqrt(Math.pow(node.x - centerX, 2) + Math.pow(node.y - centerY, 2));
      if (distFromCenter < 50) {
        const startAngle = Math.PI * 0.2;
        const endAngle = Math.PI * 0.8;
        const angle = systemProcs.length === 1
          ? (startAngle + endAngle) / 2
          : startAngle + (endAngle - startAngle) * (i / Math.max(systemProcs.length - 1, 1));
        node.x = centerX + 100 * Math.cos(angle);
        node.y = centerY + 100 * Math.sin(angle);
      }
    });

    // Run a few iterations of force simulation to settle
    for (let i = 0; i < 30; i++) {
      this.applyForces({ nodes, links, alpha: 1 - i/30 });
    }

    this.render();
    return { nodes, links, stopped: true };
  },

  applyForces(simulation) {
    const nodes = simulation.nodes;
    const links = simulation.links;
    const width = this.width;
    const height = this.height;
    const centerX = width / 2;
    const centerY = height / 2;

    // Repulsion between all non-fixed nodes (stronger)
    for (let i = 0; i < nodes.length; i++) {
      for (let j = i + 1; j < nodes.length; j++) {
        const a = nodes[i];
        const b = nodes[j];
        if (a.fx && b.fx) continue;  // Both fixed, skip
        
        let dx = b.x - a.x;
        let dy = b.y - a.y;
        let dist = Math.sqrt(dx*dx + dy*dy);
        
        if (dist < 1) {
          // Nodes at same position - nudge apart randomly
          dx = (Math.random() - 0.5) * 10;
          dy = (Math.random() - 0.5) * 10;
          dist = Math.sqrt(dx*dx + dy*dy);
        }
        
        const minDist = 70;
        if (dist < minDist) {
          const force = (minDist - dist) * 0.15;
          const fx = (dx / dist) * force;
          const fy = (dy / dist) * force;
          
          if (!b.fx) {
            b.x += fx;
            b.y += fy;
          }
          if (!a.fx) {
            a.x -= fx;
            a.y -= fy;
          }
        }
      }
    }

    // Gentle pull toward ideal radius from center (keeps layout organized)
    nodes.forEach(node => {
      if (node.fx) return;  // Skip fixed nodes
      
      const dx = node.x - centerX;
      const dy = node.y - centerY;
      const dist = Math.sqrt(dx*dx + dy*dy) || 1;
      
      const idealRadius = node.type === 'subagent' ? 110 : 
                          node.type === 'coding_agent' ? 120 : 100;
      
      const radiusForce = (dist - idealRadius) * 0.02;
      node.x -= (dx / dist) * radiusForce;
      node.y -= (dy / dist) * radiusForce;
    });

    // Keep in bounds with padding
    const padding = 50;
    nodes.forEach(node => {
      if (!node.fx) {
        node.x = Math.max(padding, Math.min(width - padding, node.x));
        node.y = Math.max(padding, Math.min(height - padding, node.y));
      }
    });
  },

  render() {
    const nodes = this.nodes;
    const links = this.links;

    // Clear groups
    this.linksGroup.innerHTML = '';
    this.nodesGroup.innerHTML = '';
    this.labelsGroup.innerHTML = '';

    // Draw links
    links.forEach(link => {
      const source = nodes.find(n => n.id === link.source);
      const target = nodes.find(n => n.id === link.target);
      if (!source || !target) return;

      const line = document.createElementNS("http://www.w3.org/2000/svg", "line");
      line.setAttribute("x1", source.x);
      line.setAttribute("y1", source.y);
      line.setAttribute("x2", target.x);
      line.setAttribute("y2", target.y);
      line.setAttribute("stroke", this.getLinkColor(link.type));
      line.setAttribute("stroke-width", link.type === 'spawned' ? 2 : 1);
      line.setAttribute("stroke-dasharray", link.type === 'monitors' ? "4,2" : "none");
      line.setAttribute("opacity", "0.6");
      this.linksGroup.appendChild(line);
    });

    // Draw nodes
    nodes.forEach(node => {
      const g = document.createElementNS("http://www.w3.org/2000/svg", "g");
      g.setAttribute("transform", `translate(${node.x}, ${node.y})`);

      // Node circle
      const circle = document.createElementNS("http://www.w3.org/2000/svg", "circle");
      const radius = this.getNodeRadius(node.type);
      circle.setAttribute("r", radius);
      circle.setAttribute("fill", this.getNodeColor(node.type));
      circle.setAttribute("stroke", this.getNodeStroke(node.type));
      circle.setAttribute("stroke-width", node.status === 'running' ? 3 : 1);
      
      // Pulse animation for running nodes
      if (node.status === 'running') {
        circle.innerHTML = `
          <animate attributeName="r" values="${radius};${radius+3};${radius}" dur="1.5s" repeatCount="indefinite"/>
          <animate attributeName="opacity" values="1;0.7;1" dur="1.5s" repeatCount="indefinite"/>
        `;
      }
      g.appendChild(circle);

      // Icon/emoji
      const icon = document.createElementNS("http://www.w3.org/2000/svg", "text");
      icon.setAttribute("text-anchor", "middle");
      icon.setAttribute("dominant-baseline", "central");
      icon.setAttribute("font-size", radius);
      icon.textContent = this.getNodeIcon(node.type);
      g.appendChild(icon);

      this.nodesGroup.appendChild(g);

      // Label
      const label = document.createElementNS("http://www.w3.org/2000/svg", "text");
      label.setAttribute("x", node.x);
      label.setAttribute("y", node.y + radius + 14);
      label.setAttribute("text-anchor", "middle");
      label.setAttribute("font-size", "10");
      label.setAttribute("font-family", "monospace");
      label.setAttribute("fill", "#8b949e");
      label.textContent = this.truncate(node.label, 15);
      this.labelsGroup.appendChild(label);
    });
  },

  getNodeColor(type) {
    const colors = {
      'main': '#238636',
      'subagent': '#9333ea',
      'coding_agent': '#f97316',
      'system': '#6b7280'
    };
    return colors[type] || '#6b7280';
  },

  getNodeStroke(type) {
    const colors = {
      'main': '#3fb950',
      'subagent': '#a855f7',
      'coding_agent': '#fb923c',
      'system': '#9ca3af'
    };
    return colors[type] || '#9ca3af';
  },

  getNodeRadius(type) {
    const sizes = {
      'main': 24,
      'subagent': 18,
      'coding_agent': 18,
      'system': 14
    };
    return sizes[type] || 14;
  },

  getNodeIcon(type) {
    const icons = {
      'main': '🦞',
      'subagent': '🤖',
      'coding_agent': '💻',
      'system': '⚙️'
    };
    return icons[type] || '●';
  },

  getLinkColor(type) {
    const colors = {
      'spawned': '#a855f7',
      'monitors': '#60a5fa',
      'parent': '#3fb950'
    };
    return colors[type] || '#6b7280';
  },

  truncate(str, max) {
    if (!str) return '';
    return str.length > max ? str.slice(0, max - 1) + '…' : str;
  }
};
